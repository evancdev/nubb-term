import SwiftUI

/// The floating tool picker at the top of the canvas.
struct CanvasToolbar: View {
    @ObservedObject var ui: CanvasUIState
    let onSelect: (CanvasTool) -> Void
    let onToggleLock: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onToggleLock) {
                Image(systemName: ui.toolLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(ui.toolLocked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Keep selected tool active after drawing (Q)")

            Divider().frame(height: 18).padding(.horizontal, 2)

            ForEach(CanvasTool.toolbar) { tool in
                Button { onSelect(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13))
                        .frame(width: 30, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(ui.tool == tool ? Color.accentColor.opacity(0.22) : .clear))
                        .foregroundStyle(ui.tool == tool ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.help(for: tool))
                .accessibilityLabel(tool.title)
            }
        }
        .padding(4)
        .canvasPanelBackground()
    }

    private static func help(for tool: CanvasTool) -> String {
        if let number = tool.number {
            return "\(tool.title) (\(tool.letter.uppercased()) or \(number))"
        }
        return "\(tool.title) (\(tool.letter.uppercased()))"
    }
}

/// Style options for the selection or the next new element.
struct CanvasStylePanel: View {
    @ObservedObject var ui: CanvasUIState
    /// Applies a style change. Changes passing the same key in quick
    /// succession, like a slider drag, are one undo step.
    let applyCoalescing: (String?, (inout CanvasStyle) -> Void) -> Void
    let onLayer: (CanvasOps.Reorder) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var style: CanvasStyle { ui.style }
    private var kinds: CanvasUIState.SelectionKinds { ui.kinds }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kinds.hasStroke || kinds.hasText {
                section("Stroke") {
                    colorRow(CanvasPalette.strokes, selected: style.strokeColor, key: "strokeColor") { value, key in
                        applyCoalescing(key) { $0.strokeColor = value }
                    }
                }
            }

            if kinds.hasFillable {
                section("Background") {
                    colorRow(CanvasPalette.backgrounds, selected: style.backgroundColor, key: "backgroundColor") { value, key in
                        applyCoalescing(key) { $0.backgroundColor = value }
                    }
                }
                section("Fill") {
                    previewSegmented(
                        [("hachure", "Hachure"), ("cross-hatch", "Cross-hatch"), ("solid", "Solid")],
                        selected: style.fillStyle,
                        set: { value in apply { $0.fillStyle = value } },
                        preview: { value in CanvasStylePreview.fill(value) })
                }
            }

            if kinds.hasStroke {
                section("Stroke width") {
                    previewSegmented(
                        [("1", "Thin"), ("2", "Bold"), ("4", "Extra bold")],
                        selected: Self.widthKey(style.strokeWidth),
                        set: { value in apply { $0.strokeWidth = Double(value) ?? 2 } },
                        preview: { value in CanvasStylePreview.stroke(width: Double(value) ?? 2, dash: nil) })
                }
                section("Stroke style") {
                    previewSegmented(
                        [("solid", "Solid"), ("dashed", "Dashed"), ("dotted", "Dotted")],
                        selected: style.strokeStyle,
                        set: { value in apply { $0.strokeStyle = value } },
                        preview: { value in
                            CanvasStylePreview.stroke(
                                width: 1.5,
                                dash: value == "dashed" ? [4, 3] : value == "dotted" ? [1, 3] : nil)
                        })
                }
                section("Sloppiness") {
                    segmented(
                        [("0", "line.diagonal"), ("1", "scribble"), ("2", "scribble.variable")],
                        selected: Self.roughnessKey(style.roughness)) { value in
                            apply { $0.roughness = Double(value) ?? 1 }
                        }
                }
            }

            if kinds.hasRoundable {
                section("Edges") {
                    segmented(
                        [("sharp", "square"), ("round", "app")],
                        selected: style.roundEdges ? "round" : "sharp") { value in
                            apply { $0.roundEdges = value == "round" }
                        }
                }
            }

            if kinds.hasArrow {
                section("Arrowheads") {
                    HStack(spacing: 6) {
                        arrowheadMenu(style.startArrowhead, start: true)
                        arrowheadMenu(style.endArrowhead, start: false)
                    }
                }
            }

            if kinds.hasText {
                section("Font") {
                    segmented(
                        CanvasFont.Family.choices.map { family in
                            (String(family.rawValue), Self.fontSymbol(family))
                        },
                        selected: String(style.fontFamily)) { value in
                            apply { $0.fontFamily = Int(value) ?? CanvasFont.Family.handDrawn.rawValue }
                        }
                }
                section("Font size") {
                    segmented(
                        [("16", "textformat.size.smaller"), ("20", "textformat.size"), ("28", "textformat.size.larger"), ("36", "textformat")],
                        selected: Self.fontSizeKey(style.fontSize)) { value in
                            apply { $0.fontSize = Double(value) ?? 20 }
                        }
                }
                section("Text align") {
                    segmented(
                        [("left", "text.alignleft"), ("center", "text.aligncenter"), ("right", "text.alignright")],
                        selected: style.textAlign) { value in apply { $0.textAlign = value } }
                }
            }

            section("Opacity") {
                Slider(
                    value: Binding(
                        get: { style.opacity },
                        set: { value in applyCoalescing("opacity") { $0.opacity = value.rounded() } }),
                    in: 0...100, step: 10)
                    .controlSize(.small)
            }

            if kinds.count > 0 {
                section("Layers") {
                    HStack(spacing: 4) {
                        iconButton("square.3.layers.3d.bottom.filled", "Send to back") { onLayer(.back) }
                        iconButton("square.2.layers.3d.bottom.filled", "Send backward") { onLayer(.backward) }
                        iconButton("square.2.layers.3d.top.filled", "Bring forward") { onLayer(.forward) }
                        iconButton("square.3.layers.3d.top.filled", "Bring to front") { onLayer(.front) }
                    }
                }
                section("Actions") {
                    HStack(spacing: 4) {
                        iconButton("plus.square.on.square", "Duplicate (⌘D)", action: onDuplicate)
                        iconButton("trash", "Delete", action: onDelete)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 204, alignment: .leading)
        .canvasPanelBackground()
    }

    private func apply(_ change: (inout CanvasStyle) -> Void) {
        applyCoalescing(nil, change)
    }

    // MARK: Pieces

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The palette plus a custom color swatch. `set` gets the color and,
    /// for the color panel, a key so a drag in it is one undo step.
    private func colorRow(
        _ colors: [String],
        selected: String,
        key: String,
        set: @escaping (String, String?) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(colors, id: \.self) { color in
                Button { set(color, nil) } label: {
                    swatch(color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    selected.lowercased() == color.lowercased() ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selected.lowercased() == color.lowercased() ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(color)
            }
            customColorButton(colors: colors, selected: selected) { set($0, key) }
        }
    }

    /// A swatch showing the current color when it isn't in the palette. It
    /// opens the system color panel, which edits the selection live.
    private func customColorButton(colors: [String], selected: String, set: @escaping (String) -> Void) -> some View {
        let isCustom = !colors.contains { $0.lowercased() == selected.lowercased() }
        return Button {
            CanvasColorPanel.shared.open(color: selected, onChange: set)
        } label: {
            ZStack {
                if isCustom {
                    swatch(selected)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center))
                        .frame(width: 22, height: 22)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isCustom ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isCustom ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help("Custom color…")
    }

    @ViewBuilder
    private func swatch(_ color: String) -> some View {
        if CanvasColor.isTransparent(color) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    Path { path in
                        path.move(to: CGPoint(x: 3, y: 19))
                        path.addLine(to: CGPoint(x: 19, y: 3))
                    }
                    .stroke(Color.red.opacity(0.7), lineWidth: 1.5))
                .frame(width: 22, height: 22)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(cgColor: CanvasColor.resolve(color, theme: ui.theme).cgColor))
                .frame(width: 22, height: 22)
        }
    }

    /// Like `segmented`, with a drawn preview of each option instead of a
    /// symbol, and a readable tooltip.
    private func previewSegmented(
        _ options: [(String, String)],
        selected: String,
        set: @escaping (String) -> Void,
        preview: @escaping (String) -> some View
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, title in
                Button { set(value) } label: {
                    preview(value)
                        .frame(width: 16, height: 14)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected == value ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                        .foregroundStyle(selected == value ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title)
            }
        }
    }

    private func segmented(_ options: [(String, String)], selected: String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, symbol in
                Button { set(value) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected == value ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                        .foregroundStyle(selected == value ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(value)
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static let arrowheads: [(String?, String)] = [
        (nil, "None"), ("arrow", "Arrow"), ("triangle", "Triangle"), ("triangle_outline", "Triangle outline"),
        ("bar", "Bar"), ("dot", "Dot"), ("circle_outline", "Circle outline"), ("diamond", "Diamond"),
        ("diamond_outline", "Diamond outline"),
    ]

    private func arrowheadMenu(_ current: String?, start: Bool) -> some View {
        Menu {
            ForEach(Self.arrowheads, id: \.1) { value, title in
                Button(title) {
                    apply { style in
                        if start { style.startArrowhead = value } else { style.endArrowhead = value }
                    }
                }
            }
        } label: {
            Text((start ? "Start: " : "End: ") + (Self.arrowheads.first { $0.0 == current }?.1 ?? (current ?? "None")))
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Keys

    private static func widthKey(_ width: Double) -> String {
        width <= 1 ? "1" : (width >= 4 ? "4" : "2")
    }

    private static func roughnessKey(_ roughness: Double) -> String {
        roughness <= 0 ? "0" : (roughness >= 2 ? "2" : "1")
    }

    private static func fontSizeKey(_ size: Double) -> String {
        switch size {
        case ..<18: "16"
        case ..<24: "20"
        case ..<32: "28"
        default: "36"
        }
    }

    private static func fontSymbol(_ family: CanvasFont.Family) -> String {
        switch CanvasFont.kind(of: family.rawValue) {
        case .handDrawn: "pencil.and.scribble"
        case .normal: "textformat"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Undo, redo, and zoom controls at the bottom left.
struct CanvasFooter: View {
    @ObservedObject var ui: CanvasUIState
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onResetZoom: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                footerButton("minus", "Zoom out (⌘-)", action: onZoomOut)
                Button(action: onResetZoom) {
                    Text("\(Int((ui.zoom * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .frame(minWidth: 44, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset zoom (⌘0)")
                footerButton("plus", "Zoom in (⌘=)", action: onZoomIn)
            }
            .canvasPanelBackground()

            HStack(spacing: 0) {
                footerButton("arrow.uturn.backward", "Undo (⌘Z)", action: onUndo)
                    .disabled(!ui.canUndo)
                footerButton("arrow.uturn.forward", "Redo (⇧⌘Z)", action: onRedo)
                    .disabled(!ui.canRedo)
            }
            .canvasPanelBackground()
        }
    }

    private func footerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown over the canvas while the file can't be read.
struct CanvasErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .canvasPanelBackground()
        .frame(maxWidth: 520)
    }
}

/// The hint shown on an empty canvas.
struct CanvasEmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Pick a tool and start drawing")
                .font(.system(size: 15, weight: .medium))
            Text("Shortcuts: R rectangle, O ellipse, A arrow, P draw, T text. Double-click to write.")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .allowsHitTesting(false)
    }
}

/// Small drawings of style options for the style panel buttons. They use
/// the button's foreground color.
enum CanvasStylePreview {
    /// A short horizontal stroke of the given width and dash.
    static func stroke(width: Double, dash: [CGFloat]?) -> some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 1, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
            context.stroke(
                path, with: .foreground,
                style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash ?? []))
        }
    }

    /// A rounded square filled the way `fillStyle` fills shapes.
    static func fill(_ fillStyle: String) -> some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let outline = Path(roundedRect: rect, cornerRadius: 3)
            if fillStyle == "solid" {
                context.fill(outline, with: .foreground)
                return
            }
            var lines = Path()
            let step: CGFloat = 3.5
            var offset = -rect.height
            while offset < rect.width {
                lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
                if fillStyle == "cross-hatch" {
                    lines.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                    lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
                }
                offset += step
            }
            var clipped = context
            clipped.clip(to: outline)
            clipped.stroke(lines, with: .foreground, lineWidth: 1)
            context.stroke(outline, with: .foreground, lineWidth: 1)
        }
    }
}

extension View {
    func canvasPanelBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
