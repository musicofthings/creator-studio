import Foundation

public struct CapturePixelDimensions: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Framework-neutral sizing policy for desktop screen capture. ScreenCaptureKit
/// supplies point dimensions and a point-to-pixel scale; the adapter asks this
/// type for an H.264-safe even pixel size with a bounded 4K working set.
public struct DesktopCaptureSizing: Sendable {
    public var maximumWidth: Int
    public var maximumHeight: Int

    public init(maximumWidth: Int = 3840, maximumHeight: Int = 2160) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }

    public func dimensions(
        pointWidth: Double,
        pointHeight: Double,
        pointPixelScale: Double
    ) -> CapturePixelDimensions? {
        guard pointWidth.isFinite,
              pointHeight.isFinite,
              pointPixelScale.isFinite,
              pointWidth > 0,
              pointHeight > 0,
              pointPixelScale > 0,
              maximumWidth >= 2,
              maximumHeight >= 2
        else { return nil }

        let sourceWidth = pointWidth * pointPixelScale
        let sourceHeight = pointHeight * pointPixelScale
        guard sourceWidth.isFinite, sourceHeight.isFinite else { return nil }

        let scale = min(
            1,
            Double(maximumWidth) / sourceWidth,
            Double(maximumHeight) / sourceHeight
        )
        return CapturePixelDimensions(
            width: Self.evenDimension(sourceWidth * scale),
            height: Self.evenDimension(sourceHeight * scale)
        )
    }

    private static func evenDimension(_ value: Double) -> Int {
        max(2, Int(value.rounded(.down)) / 2 * 2)
    }
}
