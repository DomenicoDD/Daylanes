import Carbon
import Foundation

/// Reads the current tab using the properties in Chrome's scripting dictionary.
enum ChromeTabs {
    static let bundleID = "com.google.Chrome"
    private static let work = DispatchQueue(label: "com.domenicodidonna.tracker.chrome", qos: .utility)

    enum Access: Sendable, Equatable {
        case allowed, needsPermission, denied, notRunning, unavailable
    }

    enum Reading: Sendable, Equatable {
        case tab(TabAddress, windowName: String?), normalWindow, privateWindow, unavailable
    }

    static func access(pid: pid_t, prompt: Bool = false) async -> Access {
        await withCheckedContinuation { continuation in
            work.async {
                continuation.resume(returning: status(for: NSAppleEventDescriptor(processIdentifier: pid), prompt: prompt))
            }
        }
    }

    static func read(pid: pid_t) async -> Reading {
        await withCheckedContinuation { continuation in
            work.async {
                let target = NSAppleEventDescriptor(processIdentifier: pid)
                guard status(for: target, prompt: false) == .allowed else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                let firstWindow = specifier(
                    kind: fourCC("cwin"), parent: .null(), form: DescType(formAbsolutePosition),
                    selector: NSAppleEventDescriptor(int32: 1)
                )
                let reading = readWindow(
                    frontID: {
                        guard get("pisf", of: .null(), target: target)?.booleanValue == true else { return nil }
                        return get("ID  ", of: firstWindow, target: target)?.stringValue
                    },
                    properties: { property, id in
                        let window = specifier(
                            kind: fourCC("cwin"), parent: .null(), form: DescType(formUniqueID),
                            selector: NSAppleEventDescriptor(string: id)
                        )
                        if property == .url {
                            let tab = self.property("acTa", of: window)
                            return get("URL ", of: tab, target: target)?.stringValue
                        }
                        if property == .windowName {
                            return get("GNam", of: window, target: target)?.stringValue
                        }
                        return get("mode", of: window, target: target)?.stringValue
                    }
                )
                continuation.resume(returning: reading)
            }
        }
    }

    enum WindowProperty { case mode, url, windowName }

    static func readWindow(frontID: () -> String?, properties: (WindowProperty, String) -> String?) -> Reading {
        guard let id = frontID(), let mode = properties(.mode, id) else { return .unavailable }
        if mode == "incognito" {
            return frontID() == id ? .privateWindow : .unavailable
        }
        guard mode == "normal" else { return .unavailable }
        guard let value = properties(.url, id), let address = TabAddress(value) else {
            return frontID() == id ? .normalWindow : .unavailable
        }
        let name = properties(.windowName, id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard frontID() == id else { return .unavailable }
        return .tab(address, windowName: name.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func status(for target: NSAppleEventDescriptor, prompt: Bool) -> Access {
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, prompt) {
        case noErr: .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): .needsPermission
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(procNotFound): .notRunning
        default: .unavailable
        }
    }

    private static func specifier(kind: DescType, parent: NSAppleEventDescriptor?, form: DescType,
                                  selector: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard let parent else { return nil }
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(parent, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)
    }

    private static func property(_ name: String, of parent: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        specifier(kind: cProperty, parent: parent, form: DescType(formPropertyID),
                  selector: NSAppleEventDescriptor(typeCode: fourCC(name)))
    }

    private static func get(_ name: String, of parent: NSAppleEventDescriptor?,
                            target: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard let field = property(name, of: parent) else { return nil }
        let event = NSAppleEventDescriptor(
            eventClass: kAECoreSuite, eventID: kAEGetData, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(field, forKeyword: keyDirectObject)
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.18),
              (reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0) == 0 else { return nil }
        return reply.paramDescriptor(forKeyword: keyDirectObject)
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
