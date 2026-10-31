import CoreGraphics
import Foundation

/// Resize and rotate for the selection, following Excalidraw's handles.
enum CanvasTransform {
    enum Handle: Equatable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case rotation

        /// Which sides of the box this handle moves: -1 the min side, 1 the
        /// max side, 0 neither.
        var direction: (x: Int, y: Int) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            case .rotation: (0, 0)
            }
        }

        var isCorner: Bool { direction.x != 0 && direction.y != 0 }

        /// The handle position in a box of the given size (local coordinates).
        func position(in box: CGRect) -> CGPoint {
            switch self {
            case .rotation:
                return CGPoint(x: box.midX, y: box.minY)
            default:
                let d = direction
                let x = d.x < 0 ? box.minX : (d.x > 0 ? box.maxX : box.midX)
                let y = d.y < 0 ? box.minY : (d.y > 0 ? box.maxY : box.midY)
                return CGPoint(x: x, y: y)
            }
        }
    }

    // MARK: Single element

    /// Resizes one element by dragging `handle` to `pointer` (scene
    /// coordinates). `original` is the element when the drag started.
    static func resize(
        _ original: CanvasElement,
        handle: Handle,
        to pointer: CGPoint,
        keepAspect: Bool,
        fromCenter: Bool
    ) -> CanvasElement {
        var element = original
        let box = original.localBounds
        let local = original.toLocal(pointer)
        let d = handle.direction

        var minX = Double(box.minX), maxX = Double(box.maxX)
        var minY = Double(box.minY), maxY = Double(box.maxY)
        let width0 = max(Double(box.width), 0.0001), height0 = max(Double(box.height), 0.0001)

        if d.x < 0 { minX = local.dx } else if d.x > 0 { maxX = local.dx }
        if d.y < 0 { minY = local.dy } else if d.y > 0 { maxY = local.dy }

        if fromCenter {
            let cx = Double(box.midX), cy = Double(box.midY)
            if d.x < 0 { maxX = 2 * cx - minX } else if d.x > 0 { minX = 2 * cx - maxX }
            if d.y < 0 { maxY = 2 * cy - minY } else if d.y > 0 { minY = 2 * cy - maxY }
        }

        var newWidth = maxX - minX
        var newHeight = maxY - minY

        // Text and images keep their proportions, like in Excalidraw.
        let keep = keepAspect || original.type == .text || original.type == .image
        if keep {
            let scale: Double
            if d.x != 0 && d.y != 0 {
                scale = max(abs(newWidth) / width0, abs(newHeight) / height0)
            } else if d.x != 0 {
                scale = abs(newWidth) / width0
            } else {
                scale = abs(newHeight) / height0
            }
            let signX: Double = newWidth < 0 ? -1 : 1
            let signY: Double = newHeight < 0 ? -1 : 1
            newWidth = width0 * scale * (d.x != 0 ? signX : 1)
            newHeight = height0 * scale * (d.y != 0 ? signY : 1)

            // Re-anchor at the opposite side (or center).
            if fromCenter {
                let cx = Double(box.midX), cy = Double(box.midY)
                minX = cx - abs(newWidth) / 2; maxX = cx + abs(newWidth) / 2
                minY = cy - abs(newHeight) / 2; maxY = cy + abs(newHeight) / 2
            } else {
                if d.x < 0 { minX = Double(box.maxX) - newWidth; maxX = Double(box.maxX) } else if d.x > 0 { minX = Double(box.minX); maxX = Double(box.minX) + newWidth } else {
                    minX = Double(box.midX) - newWidth / 2; maxX = Double(box.midX) + newWidth / 2
                }
                if d.y < 0 { minY = Double(box.maxY) - newHeight; maxY = Double(box.maxY) } else if d.y > 0 { minY = Double(box.minY); maxY = Double(box.minY) + newHeight } else {
                    minY = Double(box.midY) - newHeight / 2; maxY = Double(box.midY) + newHeight / 2
                }
            }
            newWidth = maxX - minX
            newHeight = maxY - minY
        }

        // Flip when dragged past the opposite side.
        let flipX = newWidth < 0
        let flipY = newHeight < 0
        let newBox = CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: max(abs(newWidth), 1), height: max(abs(newHeight), 1))

        if original.type.hasPoints {
            let sx = Double(newBox.width) / width0 * (flipX ? -1 : 1)
            let sy = Double(newBox.height) / height0 * (flipY ? -1 : 1)
            let anchorX = flipX ? Double(newBox.maxX) : Double(newBox.minX)
            let anchorY = flipY ? Double(newBox.maxY) : Double(newBox.minY)
            element.points = original.points.map { p in
                CGPoint(x: anchorX + (p.dx - Double(box.minX)) * sx, y: anchorY + (p.dy - Double(box.minY)) * sy)
            }
            if original.type == .freedraw, original.points.count == original.pressures.count {
                element.pressures = original.pressures
            }
        } else {
            element.width = Double(newBox.width)
            element.height = Double(newBox.height)
            if original.type == .text {
                let scale = Double(newBox.height) / height0
                element.fontSize = max(1, original.fontSize * scale)
            }
        }

        // Keep the new box where it is on screen: its center rotates about
        // the old center.
        let oldCenterLocal = CGPoint(x: box.midX, y: box.midY)
        let newCenterLocal = CGPoint(x: newBox.midX, y: newBox.midY)
        let oldCenterScene = original.toScene(oldCenterLocal)
        let newCenterScene = CanvasGeometry.rotate(
            CGPoint(x: newCenterLocal.dx + original.x, y: newCenterLocal.dy + original.y),
            around: oldCenterScene, by: original.angle)

        if original.type.hasPoints {
            element.x = original.x
            element.y = original.y
            let centerNow = CGPoint(x: element.x + Double(newBox.midX), y: element.y + Double(newBox.midY))
            element.x += newCenterScene.dx - centerNow.dx
            element.y += newCenterScene.dy - centerNow.dy
            CanvasOps.normalizePoints(&element)
        } else {
            element.x = newCenterScene.dx - Double(newBox.width) / 2
            element.y = newCenterScene.dy - Double(newBox.height) / 2
        }
        return element
    }

    // MARK: Multiple elements

    /// Scales several elements together by dragging a handle of their
    /// shared box. Proportions are always kept, as in Excalidraw.
    static func resizeGroup(
        _ originals: [CanvasElement],
        box: CGRect,
        handle: Handle,
        to pointer: CGPoint,
        fromCenter: Bool
    ) -> [CanvasElement] {
        let d = handle.direction
        let width0 = max(Double(box.width), 0.0001), height0 = max(Double(box.height), 0.0001)
        let anchor = CGPoint(
            x: fromCenter ? box.midX : (d.x < 0 ? box.maxX : (d.x > 0 ? box.minX : box.midX)),
            y: fromCenter ? box.midY : (d.y < 0 ? box.maxY : (d.y > 0 ? box.minY : box.midY)))
        let factor: Double = fromCenter ? 2 : 1
        let sx = d.x != 0 ? abs(pointer.dx - anchor.dx) * factor / width0 : 0
        let sy = d.y != 0 ? abs(pointer.dy - anchor.dy) * factor / height0 : 0
        let scale = max(0.01, d.x != 0 && d.y != 0 ? max(sx, sy) : max(sx, sy))

        return originals.map { original in
            var element = original
            let center = original.center
            let newCenter = CGPoint(
                x: anchor.dx + (center.dx - anchor.dx) * scale,
                y: anchor.dy + (center.dy - anchor.dy) * scale)
            if original.type.hasPoints {
                element.points = original.points.map { CGPoint(x: $0.dx * scale, y: $0.dy * scale) }
                CanvasOps.normalizePoints(&element)
            } else {
                element.width = original.width * scale
                element.height = original.height * scale
            }
            if original.type == .text {
                element.fontSize = max(1, original.fontSize * scale)
            }
            let box = element.localBounds
            element.x = newCenter.dx - Double(box.midX)
            element.y = newCenter.dy - Double(box.midY)
            return element
        }
    }

    // MARK: Rotation

    /// Rotates elements about `center` so the handle points at `pointer`.
    static func rotate(
        _ originals: [CanvasElement],
        center: CGPoint,
        from start: CGPoint,
        to pointer: CGPoint,
        snap: Bool
    ) -> [CanvasElement] {
        let startAngle = atan2(start.dy - center.dy, start.dx - center.dx)
        var delta = atan2(pointer.dy - center.dy, pointer.dx - center.dx) - startAngle
        if snap && originals.count == 1 {
            let target = CanvasGeometry.snapAngle(originals[0].angle + delta)
            delta = target - originals[0].angle
        } else if snap {
            delta = CanvasGeometry.snapAngle(delta)
        }

        return originals.map { original in
            var element = original
            let newCenter = CanvasGeometry.rotate(original.center, around: center, by: delta)
            element.angle = CanvasGeometry.normalizedAngle(original.angle + delta)
            let box = element.localBounds
            element.x = newCenter.dx - Double(box.midX)
            element.y = newCenter.dy - Double(box.midY)
            return element
        }
    }
}
