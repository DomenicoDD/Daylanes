import AppKit
import ApplicationServices

enum SlackWorkspaceDiscovery: Equatable, Sendable {
    case found([String])
    case slackClosed
    case needsAccessibility
    case unavailable

    static func discover() async -> Self {
        guard let slack = NSRunningApplication.runningApplications(withBundleIdentifier: SlackTrackingContext.desktopAppID).first else {
            return .slackClosed
        }
        guard WindowTitles.authorized else { return .needsAccessibility }
        let pid = slack.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.10)
            guard let menuBar: AXUIElement = value(app, kAXMenuBarAttribute) else { return Self.unavailable }

            // Slack gives the first workspace ⌘1. Use that shortcut to find the menu in any language,
            // and only inspect native menu metadata so refresh can run with Slack in the background.
            for menu in children(menuBar).flatMap(children).flatMap(children).flatMap(children) {
                guard let role: String = value(menu, kAXRoleAttribute), role == kAXMenuRole else { continue }
                let items = children(menu)
                guard let first = items.first, value(first, kAXMenuItemCmdCharAttribute) as String? == "1",
                      value(first, kAXMenuItemCmdModifiersAttribute) as Int? == 0 else { continue }
                let titles = items.map { value($0, kAXTitleAttribute) as String? ?? "" }
                if let names = SlackWorkspaceMenu.names(beforeSeparator: titles) { return .found(names) }
            }
            return .unavailable
        }.value
    }

    private static func children(_ item: AXUIElement) -> [AXUIElement] {
        value(item, kAXChildrenAttribute) ?? []
    }

    private static func value<T>(_ item: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
