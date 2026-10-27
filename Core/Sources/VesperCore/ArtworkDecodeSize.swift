import Foundation

/// Pixel dimensions rounded upward to share nearby layout sizes without losing display detail.
public struct ArtworkDecodeSize: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init?(width: Double, height: Double, scale: Double) {
        let pixels = [width * scale, height * scale]
        guard scale > 0, pixels.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16_384 }) else { return nil }
        self.width = Int(ceil(pixels[0] / 32)) * 32
        self.height = Int(ceil(pixels[1] / 32)) * 32
    }

    /// Aspect-fill requires enough pixels for both axes, including unusually cropped source artwork.
    public func maximumPixelSize(sourceWidth: Int, sourceHeight: Int) -> Int? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let ratio = min(1, max(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight)))
        return Int(ceil(Double(max(sourceWidth, sourceHeight)) * ratio))
    }

    public var cacheIdentifier: String { "\(width)x\(height)" }
}
