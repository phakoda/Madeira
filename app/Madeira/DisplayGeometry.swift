// Shared presentation/input geometry, independent of UIKit and Metal.
// GPL-3.0-or-later.
import Foundation

enum DisplayGeometry {
    static let fallback = CGSize(width: 1024, height: 768)
    // Defensive limit, not a promise of allocation/texture support at this size.
    static func validSize(_ size: CGSize, fallback: CGSize = fallback) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 16384, size.height <= 16384 else { return fallback }
        return size
    }
    static func aspectFit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let size = validSize(content)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }
    static func guestPoint(_ point: CGPoint, in rect: CGRect, guest: CGSize) -> (Int32, Int32) {
        let size = validSize(guest)
        guard point.x.isFinite, point.y.isFinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1) * size.width
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1) * size.height
        return (Int32(min(x, size.width - 1)), Int32(min(y, size.height - 1)))
    }
    static func sensitivity(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0.05), 20) : 2
    }
}
