import Foundation
import CoreGraphics

enum ScreenGeometry {
    static func clamp(_ point: CGPoint, to rect: CGRect, inset: CGFloat = 1) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX + inset), rect.maxX - inset), y: min(max(point.y, rect.minY + inset), rect.maxY - inset))
    }
    static func fraction(_ y: CGFloat, in rect: CGRect) -> Double { Double(min(1, max(0, (y - rect.minY) / max(1, rect.height)))) }
    static func entry(side: ScreenSide, fraction: Double, displays: [CGRect]) -> (CGPoint, CGRect)? {
        guard let rect = displays.sorted(by: { side == .left ? $0.minX < $1.minX : $0.maxX > $1.maxX }).first else { return nil }
        return (clamp(CGPoint(x: side == .left ? rect.minX + 4 : rect.maxX - 4, y: rect.minY + rect.height * fraction), to: rect), rect)
    }
    static func exit(at p: CGPoint, deltaX: Double, side: ScreenSide, displays: [CGRect]) -> CGRect? {
        guard (side == .left ? deltaX < 0 : deltaX > 0), let rect = displays.first(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else { return nil }
        let edge = side == .left ? rect.minX : rect.maxX
        guard abs(p.x - edge) <= 2 else { return nil }
        let beyond = CGPoint(x: edge + (side == .left ? -3 : 3), y: p.y)
        guard !displays.contains(where: { $0.contains(beyond) }) else { return nil }
        return rect
    }
    static func project(_ p: CGPoint, displays: [CGRect]) -> CGPoint {
        if displays.contains(where: { $0.contains(p) }) { return p }
        return displays.map { clamp(p, to: $0) }.min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }) ?? p
    }
}
