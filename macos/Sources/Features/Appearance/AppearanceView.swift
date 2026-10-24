import AppKit
import SwiftUI

/// The Appearance window: pick a theme, preview it, and override colors.
struct AppearanceView: View {
    @ObservedObject var model: AppearanceModel

    /// List tag for the "Nubb Default" row. Theme names can't contain NUL.
    private static let defaultTag = "\u{0}default"

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search themes", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Picker("Show", selection: $model.brightness) {
                    ForEach(AppearanceModel.Brightness.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                List(selection: selection) {
                    if model.mode == .single && model.search.isEmpty && model.brightness == .all {
                        ThemeRow(name: "Nubb Default", colors: ResolvedColors(ThemeColors()), badge: nil)
                            .tag(Self.defaultTag)
                            .id(Self.defaultTag)
                    }
                    ForEach(model.filteredThemes) { theme in
                        ThemeRow(
                            name: theme.name,
                            colors: theme.resolved,
                            badge: theme.location == .user ? "Yours" : nil
                        )
                        .tag(theme.name)
                        .id(theme.name)
                    }
                }
                .listStyle(.sidebar)
                .onAppear {
                    proxy.scrollTo(model.selectedName ?? Self.defaultTag, anchor: .center)
                }
            }

            Divider()

            HStack {
                Text("\(model.filteredThemes.count) themes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Themes Folder") { model.openUserThemesFolder() }
                    .help("Add theme files here to use them in Nubb")
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload theme files")
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedName ?? Self.defaultTag },
            set: { new in
                guard let new else { return }
                model.select(new == Self.defaultTag ? nil : new)
            }
        )
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modePicker
                TerminalPreview(colors: model.previewColors)
                customizeColors
                customizePalette
                footer
            }
            .padding(20)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Theme", selection: modeBinding) {
                Text("One Theme").tag(AppearanceModel.Mode.single)
                Text("Match macOS Light and Dark").tag(AppearanceModel.Mode.pair)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.mode == .pair {
                Picker("Editing", selection: $model.slot) {
                    Text("Light: \(model.settings.theme.light ?? "Nubb Default")").tag(AppearanceModel.Slot.light)
                    Text("Dark: \(model.settings.theme.dark ?? "Nubb Default")").tag(AppearanceModel.Slot.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Pick a theme from the list for each mode. Nubb switches when macOS does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.selectedName ?? "Nubb Default")
                    .font(.title2.weight(.semibold))
            }
        }
    }

    private var modeBinding: Binding<AppearanceModel.Mode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    private var customizeColors: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Colors", detail: "Changes apply on top of the theme.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(ThemeColorKey.allCases) { key in
                    ColorWell(
                        label: key.label,
                        color: model.previewColors.value(for: key),
                        overridden: model.isOverridden(key),
                        onChange: { model.setOverride(key, $0) },
                        onReset: { model.setOverride(key, nil) }
                    )
                }
            }
        }
    }

    private var customizePalette: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Palette", detail: "The 16 colors programs use. Top row is normal, bottom row is bright.")
            ForEach(0..<2) { row in
                HStack(spacing: 8) {
                    ForEach(0..<8) { col in
                        let index = row * 8 + col
                        PaletteWell(
                            index: index,
                            color: model.previewColors.palette[index],
                            overridden: model.isOverridden(palette: index),
                            onChange: { model.setOverride(palette: index, $0) },
                            onReset: { model.setOverride(palette: index, nil) }
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                if model.hasOverrides {
                    Button("Reset Colors to Theme") { model.clearOverrides() }
                }
                Spacer()
                Button("Show Settings File") { model.revealAppearanceFile() }
            }
            if let error = model.lastError {
                Text("Couldn't save: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Saved to \(model.appearanceURL.lastPathComponent). Open terminals update right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows and wells

private struct ThemeRow: View {
    let name: String
    let colors: ResolvedColors
    let badge: String?

    var body: some View {
        HStack(spacing: 8) {
            ThemeSwatch(colors: colors)
                .frame(width: 52, height: 22)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small chip showing a theme's background, text, and accent colors.
private struct ThemeSwatch: View {
    let colors: ResolvedColors

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colors.background.color)
            .overlay(
                HStack(spacing: 2) {
                    Text("A")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(colors.foreground.color)
                    ForEach([1, 2, 3, 4, 5], id: \.self) { i in
                        Circle()
                            .fill(colors.palette[i].color)
                            .frame(width: 5, height: 5)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }
}

private struct ColorWell: View {
    let label: String
    let color: ThemeRGB
    let overridden: Bool
    let onChange: (ThemeRGB) -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker(label, selection: binding, supportsOpacity: false)
            if overridden {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Use the theme's color")
            }
        }
    }

    private var binding: Binding<Color> {
        Binding(get: { color.color }, set: { if let rgb = ThemeRGB(color: $0) { onChange(rgb) } })
    }
}

private struct PaletteWell: View {
    let index: Int
    let color: ThemeRGB
    let overridden: Bool
    let onChange: (ThemeRGB) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ColorPicker("Color \(index)", selection: binding, supportsOpacity: false)
                .labelsHidden()
            Text("\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(overridden ? Color.accentColor : Color.secondary)
        }
        .contextMenu {
            if overridden {
                Button("Use the Theme's Color", action: onReset)
            }
        }
    }

    private var binding: Binding<Color> {
        Binding(get: { color.color }, set: { if let rgb = ThemeRGB(color: $0) { onChange(rgb) } })
    }
}

// MARK: - Terminal preview

/// A fake terminal drawn with the chosen colors.
private struct TerminalPreview: View {
    let colors: ResolvedColors

    /// Where a piece of preview text takes its color from.
    private enum Ink {
        case text
        case palette(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line([("user@host", .palette(2)), (" ~/project", .palette(4)), (" (main)", .palette(5)), (" $ ", .text), ("ls", .text)])
            line([("README.md  ", .text), ("src  ", .palette(4)), ("tests  ", .palette(4)), ("build.sh", .palette(2))])
            line([("user@host", .palette(2)), (" ~/project", .palette(4)), (" (main)", .palette(5)), (" $ ", .text), ("git diff", .text)])
            line([("@@ -1,2 +1,2 @@", .palette(6))])
            line([("- let color = \"old\"", .palette(1))])
            line([("+ let color = \"new\"", .palette(2))])
            line([("warning: ", .palette(3)), ("1 file changed", .text)])
            line([("error: ", .palette(9)), ("tests failed", .palette(8))])
            HStack(spacing: 0) {
                Text("selected text")
                    .foregroundColor(colors.selectionForeground.color)
                    .background(colors.selectionBackground.color)
                Text(" and normal text")
                    .foregroundColor(colors.foreground.color)
            }
            HStack(spacing: 0) {
                line([("user@host", .palette(2)), (" ~/project", .palette(4)), (" $ ", .text)])
                Text("_")
                    .foregroundColor(colors.cursorText.color)
                    .background(colors.cursor.color)
            }
            HStack(spacing: 4) {
                ForEach(0..<16) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colors.palette[i].color)
                        .frame(width: 16, height: 10)
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func line(_ parts: [(String, Ink)]) -> Text {
        var result = AttributedString()
        for (text, ink) in parts {
            var piece = AttributedString(text)
            piece.foregroundColor = color(ink)
            result += piece
        }
        return Text(result)
    }

    private func color(_ ink: Ink) -> Color {
        switch ink {
        case .text: colors.foreground.color
        case .palette(let i): colors.palette[i].color
        }
    }
}

// MARK: - Color conversion

extension ThemeRGB {
    var color: Color {
        Color(nsColor: NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        ))
    }

    init?(color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(rgb.redComponent), g: byte(rgb.greenComponent), b: byte(rgb.blueComponent))
    }
}
