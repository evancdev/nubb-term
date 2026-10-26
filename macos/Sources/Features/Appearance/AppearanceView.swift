import AppKit
import Combine
import SwiftUI

/// The Appearance window: pick a theme at the top, see it in a sample
/// terminal, and change any color by clicking it in the sample or in the
/// list on the right.
struct AppearanceView: View {
    @ObservedObject var model: AppearanceModel

    /// Picker tag for Nubb's default colors. Theme names can't contain NUL.
    private static let defaultTag = "\u{0}default"

    /// What the mouse is over, in the sample or the list. The id tells
    /// apart neighbors that share a color, so leaving one doesn't clear
    /// the other.
    @State private var hover: (id: String, slot: ColorSlot)?
    @State private var hoverBackground = false

    /// The color the color panel is editing.
    @State private var editing: ColorSlot?
    @State private var confirmTrash = false

    private var highlight: ColorSlot? {
        hover?.slot ?? (hoverBackground ? .key(.background) : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TerminalPreview(
                        colors: model.previewColors,
                        highlight: highlight,
                        onHover: setHover,
                        onHoverBackground: { hoverBackground = $0 },
                        onPick: edit
                    )
                    status
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(ColorSlot.all) { slot in
                            ColorRow(
                                slot: slot,
                                colors: model.previewColors,
                                highlighted: highlight == slot,
                                editing: editing == slot,
                                onHover: { setHover("row-\(slot.id)", slot, $0) },
                                onPick: { edit(slot) }
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(width: 320)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: $model.namePrompt) { prompt in
            NameSheet(
                prompt: prompt,
                problem: model.nameProblem,
                onCancel: { model.namePrompt = nil },
                onSave: { model.commit($0) }
            )
        }
        .confirmationDialog(
            "Move \u{201C}\(model.editableTheme?.name ?? "")\u{201D} to the Trash?",
            isPresented: $confirmTrash
        ) {
            Button("Move to Trash", role: .destructive) { model.trashSelectedTheme() }
        }
        .onReceive(model.objectWillChange) { _ in
            // objectWillChange fires before the change lands.
            DispatchQueue.main.async { syncPanel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard note.object is NSColorPanel else { return }
            editing = nil
            AppearanceColorPanel.shared.detach()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Theme", selection: themeBinding) {
                Text("Nubb Default").tag(Self.defaultTag)
                if !model.userThemes.isEmpty {
                    Section("My Themes") {
                        ForEach(model.userThemes) { Text($0.name).tag($0.name) }
                    }
                }
                Section("Themes") {
                    ForEach(model.bundledThemes) { Text($0.name).tag($0.name) }
                }
            }
            .labelsHidden()
            .frame(width: 260)

            Button { model.step(by: -1) } label: { Image(systemName: "chevron.left") }
                .help("Previous theme")
            Button { model.step(by: 1) } label: { Image(systemName: "chevron.right") }
                .help("Next theme")

            if model.editableTheme != nil {
                Text("My Theme")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }

            Spacer()

            Button { model.beginCreate() } label: { Label("New Theme", systemImage: "plus") }
                .help("Save the current colors as a new theme of your own")

            Menu {
                if model.editableTheme != nil {
                    Button("Rename\u{2026}") { model.beginRename() }
                    Button("Move to Trash\u{2026}", role: .destructive) { confirmTrash = true }
                    Divider()
                }
                Button("Show Themes Folder") { model.openUserThemesFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { model.selectedName ?? Self.defaultTag },
            set: { model.select($0 == Self.defaultTag ? nil : $0) }
        )
    }

    private var hint: String {
        let save = model.editableTheme != nil
            ? "Changes save into this theme."
            : "Your first change saves a copy to My Themes."
        return "Click any word or the background to change its color. \(save)"
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.lastError {
            Text("Couldn't save: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.hasLightDarkPair {
            Text("Your config uses separate light and dark themes. Picking a theme here uses it for both.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Editing

    private func setHover(_ id: String, _ slot: ColorSlot, _ inside: Bool) {
        if inside {
            hover = (id, slot)
        } else if hover?.id == id {
            hover = nil
        }
    }

    private func edit(_ slot: ColorSlot) {
        editing = slot
        AppearanceColorPanel.shared.open(color: model.previewColors[slot]) { [model] rgb in
            model.setColor(slot, rgb)
        }
    }

    /// Points the color panel at the right color after the theme changes.
    private func syncPanel() {
        guard let slot = editing else { return }
        AppearanceColorPanel.shared.sync(color: model.previewColors[slot])
    }
}

// MARK: - Color panel

/// Connects the shared macOS color panel to one color at a time.
@MainActor
final class AppearanceColorPanel: NSObject {
    static let shared = AppearanceColorPanel()

    private var onChange: ((ThemeRGB) -> Void)?

    func open(color: ThemeRGB, onChange: @escaping (ThemeRGB) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color.nsColor
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    /// Shows `color` without reporting it back as a change. Skipped when
    /// the panel already shows it, so a drag in progress isn't disturbed.
    func sync(color: ThemeRGB) {
        let panel = NSColorPanel.shared
        guard onChange != nil, ThemeRGB(nsColor: panel.color) != color else { return }
        panel.setTarget(nil)
        panel.color = color.nsColor
        panel.setTarget(self)
    }

    /// Stops editing. Closes the panel too if asked.
    func detach(closePanel: Bool = false) {
        guard onChange != nil else { return }
        onChange = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if closePanel { panel.orderOut(nil) }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let rgb = ThemeRGB(nsColor: sender.color) else { return }
        onChange?(rgb)
    }
}

// MARK: - Color list

private struct ColorRow: View {
    let slot: ColorSlot
    let colors: ResolvedColors
    let highlighted: Bool
    let editing: Bool
    let onHover: (Bool) -> Void
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                SampleChip(slot: slot, colors: colors)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.name)
                    Text(slot.usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .help("\(slot.name): \(colors[slot].hex)")
    }

    private var fill: Color {
        if editing { return Color.accentColor.opacity(0.25) }
        if highlighted { return Color.primary.opacity(0.08) }
        return .clear
    }
}

/// "Hello World" drawn the way the slot's color is used.
private struct SampleChip: View {
    let slot: ColorSlot
    let colors: ResolvedColors

    var body: some View {
        sample
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .frame(width: 104, height: 24)
            .background(colors.background.color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private var sample: Text {
        let fg = colors.foreground.color
        switch slot {
        case .key(.background), .key(.foreground):
            return Text("Hello World").foregroundColor(fg)
        case .key(.cursorColor), .key(.cursorText):
            var cursor = AttributedString("W")
            cursor.foregroundColor = colors.cursorText.color
            cursor.backgroundColor = colors.cursor.color
            return Text("Hello ").foregroundColor(fg) + Text(cursor) + Text("orld").foregroundColor(fg)
        case .key(.selectionBackground), .key(.selectionForeground):
            var selected = AttributedString("Hello World")
            selected.foregroundColor = colors.selectionForeground.color
            selected.backgroundColor = colors.selectionBackground.color
            return Text(selected)
        case .palette(0):
            var label = AttributedString("Hello World")
            label.foregroundColor = colors.palette[0].color
            label.backgroundColor = colors.palette[2].color
            return Text(label).bold()
        case .palette(let index):
            return Text("Hello World").foregroundColor(colors.palette[index].color)
        }
    }
}

// MARK: - Terminal preview

/// The sample terminal text. Every color in `ColorSlot.all` shows up in it
/// (the background behind all of it), so any color can be found by hovering.
enum PreviewScript {
    enum Piece {
        /// Text in one color.
        case ink(String, ColorSlot)
        /// Text on a colored block, like a label, a selection, or the cursor.
        case block(String, text: ColorSlot, fill: ColorSlot)
        /// Spacing between words, in the plain text color.
        case gap(String)

        /// The color a click changes.
        var primary: ColorSlot? {
            switch self {
            case .ink(_, let slot): slot
            case .block(_, _, let fill): fill
            case .gap: nil
            }
        }

        /// Every color this piece shows.
        var slots: [ColorSlot] {
            switch self {
            case .ink(_, let slot): [slot]
            case .block(_, let text, let fill): [text, fill]
            case .gap: []
            }
        }
    }

    private static let text = ColorSlot.key(.foreground)

    private static let prompt: [Piece] = [
        .ink("user@host", .palette(2)), .gap(" "),
        .ink("~/project", .palette(4)), .gap(" "),
        .ink("(main)", .palette(5)), .gap(" "),
        .ink("$", text), .gap(" "),
    ]

    static let lines: [[Piece]] = [
        prompt + [.ink("echo \"Hello World\"", text)],
        [.ink("Hello World", text)],
        prompt + [.ink("git log -1 --oneline", text)],
        [.ink("a1b2c3d", .palette(3)), .gap(" "), .ink("(HEAD -> main)", .palette(6)), .gap(" "), .ink("add a greeting", text)],
        prompt + [.ink("ls", text)],
        [
            .ink("README.md", text), .gap("  "), .ink("src", .palette(4)), .gap("  "),
            .ink("tests", .palette(4)), .gap("  "), .ink("latest", .palette(5)), .gap(" "), .ink("-> build", text),
        ],
        prompt + [.ink("git diff", text)],
        [.ink("@@ -1,2 +1,2 @@", .palette(6))],
        [.ink("- let greeting = \"Hi\"", .palette(1))],
        [.ink("+ let greeting = \"Hello World\"", .palette(2))],
        [.ink("warning:", .palette(3)), .gap(" "), .ink("1 file changed", text)],
        [
            .block(" PASS ", text: .palette(0), fill: .palette(2)), .gap(" "),
            .ink("412 passed", .palette(10)), .gap("  "), .ink("2 skipped", .palette(11)), .gap("  "),
            .ink("1 failed", .palette(9)), .gap("  "), .ink("(2.1s)", .palette(8)),
        ],
        [.block(" FAIL ", text: .palette(15), fill: .palette(1)), .gap(" "), .ink("error: expected 3, got 4", .palette(1))],
        [.ink("INFO ", .palette(12)), .gap(" "), .ink("serving", text), .gap(" "), .ink("http://localhost:3000", .palette(14))],
        [.ink("DEBUG", .palette(13)), .gap(" "), .ink("cache warm", .palette(7))],
        [.block("selected text", text: .key(.selectionForeground), fill: .key(.selectionBackground)), .ink(" and normal text", text)],
        prompt + [.block(" ", text: .key(.cursorText), fill: .key(.cursorColor))],
    ]
}

private struct TerminalPreview: View {
    let colors: ResolvedColors
    let highlight: ColorSlot?
    let onHover: (String, ColorSlot, Bool) -> Void
    let onHoverBackground: (Bool) -> Void
    let onPick: (ColorSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(PreviewScript.lines.indices, id: \.self) { line in
                HStack(spacing: 0) {
                    ForEach(PreviewScript.lines[line].indices, id: \.self) { index in
                        piece(PreviewScript.lines[line][index], id: "run-\(line)-\(index)")
                    }
                }
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(highlight == .key(.background) ? 0.6 : 0.12), lineWidth: highlight == .key(.background) ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onPick(.key(.background)) }
        .onHover(perform: onHoverBackground)
        .help("Background: \(colors.background.hex)")
    }

    @ViewBuilder
    private func piece(_ piece: PreviewScript.Piece, id: String) -> some View {
        let dimmed = highlight != nil && !piece.slots.contains { $0 == highlight }
        switch piece {
        case .gap(let text):
            Text(text)
        case .ink(let text, let slot):
            interactive(Text(text).foregroundColor(colors[slot].color), piece: piece, id: id, dimmed: dimmed)
        case .block(let text, let ink, let fill):
            interactive(
                Text(text).foregroundColor(colors[ink].color).bold(fill.isPalette).background(colors[fill].color),
                piece: piece,
                id: id,
                dimmed: dimmed
            )
        }
    }

    private func interactive(_ view: some View, piece: PreviewScript.Piece, id: String, dimmed: Bool) -> some View {
        let slot = piece.primary ?? .key(.foreground)
        let lit = highlight.map { piece.slots.contains($0) } ?? false
        return view
            .opacity(dimmed ? 0.15 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(lit ? 0.75 : 0), lineWidth: 1.5)
                    .padding(-2)
            )
            .contentShape(Rectangle())
            .onHover { onHover(id, slot, $0) }
            .onTapGesture { onPick(slot) }
            .help("\(slot.name): \(colors[slot].hex)")
    }
}

private extension ColorSlot {
    var isPalette: Bool {
        if case .palette = self { return true }
        return false
    }
}

// MARK: - Name sheet

private struct NameSheet: View {
    let prompt: AppearanceModel.NamePrompt
    let problem: (AppearanceModel.NamePrompt) -> String?
    let onCancel: () -> Void
    let onSave: (AppearanceModel.NamePrompt) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(
        prompt: AppearanceModel.NamePrompt,
        problem: @escaping (AppearanceModel.NamePrompt) -> String?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AppearanceModel.NamePrompt) -> Void
    ) {
        self.prompt = prompt
        self.problem = problem
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: prompt.name)
    }

    private var edited: AppearanceModel.NamePrompt {
        var copy = prompt
        copy.name = name
        return copy
    }

    private var title: String {
        switch prompt.kind {
        case .create: "New Theme"
        case .rename: "Rename Theme"
        }
    }

    var body: some View {
        let issue = problem(edited)
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if prompt.kind == .create {
                Text("Saves the colors you see now to your themes folder. Changes to it save automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if issue == nil { onSave(edited) } }
            Text(issue ?? " ")
                .font(.caption)
                .foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.kind == .create ? "Create" : "Rename") { onSave(edited) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

// MARK: - Color conversion

extension ThemeRGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var color: Color { Color(nsColor: nsColor) }

    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(rgb.redComponent), g: byte(rgb.greenComponent), b: byte(rgb.blueComponent))
    }
}
