import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppRuleField: View {
    @Binding var name: String
    @Binding var appID: String?
    @Binding var manual: Bool
    var optional = false
    @State private var showApps = false
    @State private var browse = false
    @State private var pickedApp: InstalledMacApp?
    @State private var error: String?

    var body: some View {
        SheetField(label: optional ? "Only in app" : manual ? "App name contains" : "App",
                   note: optional ? "optional" : nil) {
            if manual {
                SheetTextField(placeholder: "e.g. Xcode", text: $name)
            }
            Button {
                showApps = true
            } label: {
                if manual {
                    Text("Choose an installed app")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(SheetTheme.accent)
                } else {
                    HStack(spacing: 8) {
                        if let appID {
                            if let url = pickedApp?.id == appID ? pickedApp?.url
                                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
                                AppIconImage(url: url)
                            }
                            Text(name).lineLimit(1)
                        } else {
                            Text(optional ? "Any app" : "Choose an installed app").foregroundStyle(SheetTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SheetTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .modifier(FieldBox(focused: showApps))
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appID == nil ? (optional ? "Only in app, any app" : "Choose an installed app") : "App, \(name)")
            .popover(isPresented: $showApps, arrowEdge: .bottom) {
                InstalledAppPicker(selectedID: appID, select: choose) {
                    showApps = false
                    browse = true
                }
            }
            HStack {
                if !manual {
                    Button("Match by app name") {
                        manual = true
                        appID = nil
                        error = nil
                    }
                }
                if optional && (manual || appID != nil) {
                    Button("Clear app restriction") {
                        name = ""
                        appID = nil
                        manual = false
                        error = nil
                    }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $browse, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let app = InstalledMacApp(url: url) else {
                    error = "Choose a Mac app that can appear in the foreground."
                    return
                }
                choose(app)
            } catch {
                self.error = "Couldn’t open the selected app. Try choosing it again."
            }
        }
    }

    private func choose(_ app: InstalledMacApp) {
        pickedApp = app
        name = app.name
        appID = app.id
        manual = false
        error = nil
        showApps = false
    }
}

private struct InstalledAppPicker: View {
    let selectedID: String?
    let select: (InstalledMacApp) -> Void
    let browse: () -> Void
    @State private var apps: [InstalledMacApp] = []
    @State private var loading = true
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let query = search.trimmed
        let matches = apps.filter { $0.matches(query) }
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search installed apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if matches.count == 1, let app = matches.first { select(app) } }
            ScrollView {
                if loading {
                    ProgressView("Finding apps…").controlSize(.small).padding(.vertical, 10)
                } else if matches.isEmpty {
                    Text(query.isEmpty ? "No apps found. Use Browse to select one." : "No apps match your search.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { app in
                        Button { select(app) } label: {
                            HStack(spacing: 8) {
                                AppIconImage(url: app.url)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).lineLimit(1)
                                    if apps.contains(where: { $0.id != app.id && $0.name == app.name }) {
                                        Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if app.id == selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 3)
                        .accessibilityAddTraits(app.id == selectedID ? .isSelected : [])
                    }
                }
            }
            .frame(height: 220)
            Divider()
            Button("Browse…", action: browse).buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 340)
        .task {
            searchFocused = true
            let catalog = await Task.detached(priority: .userInitiated) {
                InstalledMacApp.catalog()
            }.value
            guard !Task.isCancelled else { return }
            apps = catalog
            loading = false
        }
    }
}

private struct AppIconImage: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}
