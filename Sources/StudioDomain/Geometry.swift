import Foundation

public struct NormalizedPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NormalizedSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct NormalizedRect: Hashable, Codable, Sendable {
    public var origin: NormalizedPoint
    public var size: NormalizedSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = NormalizedPoint(x: x, y: y)
        self.size = NormalizedSize(width: width, height: height)
    }

    public static let fullFrame = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    public var isPositive: Bool { size.width > 0 && size.height > 0 }

    public func clampedToFrame() -> NormalizedRect {
        let x = min(max(origin.x, 0), 1)
        let y = min(max(origin.y, 0), 1)
        let width = min(max(size.width, 0), 1 - x)
        let height = min(max(size.height, 0), 1 - y)
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

public struct CanvasSpec: Hashable, Codable, Sendable {
    public enum Orientation: String, Codable, Sendable {
        case landscape
        case portrait
        case square
        case custom
    }

    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var orientation: Orientation {
        if width == height { return .square }
        return width > height ? .landscape : .portrait
    }

    public static let landscape1080 = CanvasSpec(width: 1920, height: 1080)
    public static let vertical1080 = CanvasSpec(width: 1080, height: 1920)
    public static let square1080 = CanvasSpec(width: 1080, height: 1080)
}
