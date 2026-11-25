import AppKit
import SwiftUI

/// The look shared by every sheet: a dark header on the app's chrome colour that names what you act on,
/// a white body with labels above the fields, and a footer with Cancel and one primary button.
enum SheetTheme {
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }

    static let header = Theme.chrome
    static let headerChip = Color(nsColor: NSColor(hex: 0x2A2A2F))
    static let headerChipText = Color(nsColor: NSColor(hex: 0xD4D4D8))
    static let headerMuted = Color(nsColor: NSColor(hex: 0xA1A1AA))
    static let body = dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let field = dynamic(light: 0xF7F7F8, dark: 0x26262A)
    static let fieldFocused = dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let border = dynamic(light: 0xE4E4E7, dark: 0x3A3A3F)
    static let label = dynamic(light: 0x52525B, dark: 0xA1A1AA)
    static let muted = dynamic(light: 0x71717A, dark: 0x8E8E93)
    static let soft = dynamic(light: 0xF4F4F5, dark: 0x2A2A2E)
    static let footerLine = dynamic(light: 0xEFEFF1, dark: 0x2A2A2E)
    static let accent = Theme.accent
}

/// The frame of a sheet. The header shows `title` (with an optional colour dot or icon), small context chips
/// and a muted line; `content` sits in the white body; the footer has `leading` on the left, then Cancel and
/// the primary button, which stays greyed out until `canSubmit`.
struct SheetFrame<Content: View, Leading: View>: View {
    let title: String
    let dot: Color?
    let chips: [String]
    let subtitle: String?
    let monoSubtitle: Bool
    let primary: String
    let cancelTitle: String
    let canSubmit: Bool
    let busy: Bool
    let width: CGFloat
    let submit: () -> Void
    let content: () -> Content
    let leading: () -> Leading
    @Environment(\.dismiss) private var dismiss

    init(title: String, dot: Color? = nil, chips: [String] = [], subtitle: String? = nil, monoSubtitle: Bool = false,
         primary: String, cancelTitle: String = "Cancel", canSubmit: Bool = true, busy: Bool = false, width: CGFloat = 520,
         submit: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.title = title
        self.dot = dot
        self.chips = chips
        self.subtitle = subtitle
        self.monoSubtitle = monoSubtitle
        self.primary = primary
        self.cancelTitle = cancelTitle
        self.canSubmit = canSubmit
        self.busy = busy
        self.width = width
        self.submit = submit
        self.content = content
        self.leading = leading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(width: width)
        .background(SheetTheme.body)
        .foregroundStyle(Theme.text)
        .tint(SheetTheme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let dot { Circle().fill(dot).frame(width: 11, height: 11) }
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .buttonStyle(CircleButtonStyle(dark: true))
                    .disabled(busy)
                    .help("Close")
            }
            if !chips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        Text(chip)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SheetTheme.headerChipText)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SheetTheme.headerChip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(monoSubtitle ? .system(size: 11, design: .monospaced) : .callout)
                    .foregroundStyle(SheetTheme.headerMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SheetTheme.header)
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            Button(cancelTitle, role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SheetButtonStyle(kind: .secondary))
                .disabled(busy)
            Button(primary, action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SheetButtonStyle(kind: .primary))
                .disabled(!canSubmit || busy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(SheetTheme.footerLine).frame(height: 1) }
    }
}

extension SheetFrame where Leading == EmptyView {
    init(title: String, dot: Color? = nil, chips: [String] = [], subtitle: String? = nil, monoSubtitle: Bool = false,
         primary: String, cancelTitle: String = "Cancel", canSubmit: Bool = true, busy: Bool = false, width: CGFloat = 520,
         submit: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, dot: dot, chips: chips, subtitle: subtitle, monoSubtitle: monoSubtitle, primary: primary,
                  cancelTitle: cancelTitle, canSubmit: canSubmit, busy: busy, width: width, submit: submit,
                  content: content, leading: { EmptyView() })
    }
}

/// Cancel, the primary action, or a plain text link such as "+ New project".
struct SheetButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, link, destructive }
    let kind: Kind
    @Environment(\.isEnabled) var enabled

    init(kind: Kind) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .link ? 6 : 15)
            .frame(height: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: enabled ? Theme.text : SheetTheme.muted
        case .link: enabled ? SheetTheme.accent : SheetTheme.muted
        case .destructive: enabled ? Theme.recording : SheetTheme.muted
        }
    }

    private var background: Color {
        switch kind {
        case .primary: SheetTheme.accent.opacity(enabled ? 1 : 0.35)
        case .secondary: SheetTheme.soft
        case .link, .destructive: .clear
        }
    }
}

/// A label above a field. `note` follows the label in lighter text, such as "optional".
struct SheetField<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(label).foregroundColor(SheetTheme.label)
             + Text(note.map { " · \($0)" } ?? "").font(.system(size: 12)).foregroundColor(SheetTheme.muted))
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }
}

/// The 40 pt rounded box every field shares, with the accent ring while focused.
struct FieldBox: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(focused ? SheetTheme.fieldFocused : SheetTheme.field,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? SheetTheme.accent : SheetTheme.border, lineWidth: focused ? 1.5 : 1))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SheetTheme.accent.opacity(focused ? 0.15 : 0)).padding(-3))
    }
}

struct SheetTextField: View {
    let placeholder: String
    @Binding var text: String
    var prefix: String?
    var suffix: String?
    var mono = false
    var numeric = false
    var autofocus = false
    @FocusState private var focused: Bool

    init(placeholder: String, text: Binding<String>, prefix: String? = nil, suffix: String? = nil,
         mono: Bool = false, numeric: Bool = false, autofocus: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.prefix = prefix
        self.suffix = suffix
        self.mono = mono
        self.numeric = numeric
        self.autofocus = autofocus
    }

    var body: some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix).foregroundStyle(SheetTheme.muted) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .multilineTextAlignment(numeric ? .trailing : .leading)
                .font(mono ? .system(size: 12, design: .monospaced)
                      : .system(size: numeric ? 15 : 14, weight: numeric ? .semibold : .regular))
                .monospacedDigit()
            if let suffix { Text(suffix).foregroundStyle(SheetTheme.muted) }
        }
        .font(.system(size: 14))
        .modifier(FieldBox(focused: focused))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }
}

/// A field-shaped pop-up menu. Options come in groups separated by dividers.
struct SheetMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let groups: [[(Value, String)]]
    var placeholder = "Choose…"
    var dot: ((Value) -> Color?)?

    private var current: (Value, String)? {
        groups.joined().first { $0.0 == selection }
    }

    var body: some View {
        Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(Array(group.enumerated()), id: \.offset) { _, option in
                    Button(option.1) { selection = option.0 }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let current, let color = dot?(current.0) {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(current?.1 ?? placeholder)
                    .foregroundStyle(current == nil ? SheetTheme.muted : Theme.text)
                    .fontWeight(current == nil ? .regular : .medium)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SheetTheme.muted)
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(FieldBox(focused: false))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// A full-width segmented control, such as Client work / Internal / Personal.
struct SheetSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : SheetTheme.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(selected ? SheetTheme.fieldFocused : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(SheetTheme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A small round-cornered choice, used for quick durations and activity kinds.
struct SheetChip: View {
    let title: String
    var selected = false
    var outlined = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Theme.text)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(selected ? Theme.chrome : (outlined ? SheetTheme.body : SheetTheme.soft), in: Capsule())
                .overlay(Capsule().strokeBorder(outlined && !selected ? SheetTheme.border : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A soft grey panel with a title, a one-line explanation and a switch.
struct SheetOption: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A grey panel that groups related fields, such as the client and a new client's name.
struct SheetGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
