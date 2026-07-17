import Foundation

public struct PixelPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SlideGeometry: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ROIError.invalidSlideGeometry }
        self.width = width
        self.height = height
    }
}

public enum ROIShape: String, Codable, Sendable {
    case rectangle
    case ellipse
    case polygon
    case freehand
}

public enum ROIError: Error, Equatable {
    case invalidSlideGeometry
    case insufficientPoints
    case pointOutsideSlide
}

/// ROI coordinates are stored relative to the level-0 slide canvas.
/// This makes copying deterministic even when target slides have different dimensions.
public struct NormalizedROI: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let shape: ROIShape
    public let points: [PixelPoint]

    public init(
        id: UUID = UUID(),
        name: String,
        shape: ROIShape,
        pixelPoints: [PixelPoint],
        source: SlideGeometry
    ) throws {
        guard pixelPoints.count >= (shape == .polygon ? 3 : 2) else {
            throw ROIError.insufficientPoints
        }
        guard pixelPoints.allSatisfy({
            $0.x >= 0 && $0.y >= 0 && $0.x <= Double(source.width) && $0.y <= Double(source.height)
        }) else {
            throw ROIError.pointOutsideSlide
        }

        self.id = id
        self.name = name
        self.shape = shape
        self.points = pixelPoints.map {
            PixelPoint(x: $0.x / Double(source.width), y: $0.y / Double(source.height))
        }
    }

    public func pixelPoints(on target: SlideGeometry) -> [PixelPoint] {
        points.map {
            PixelPoint(x: $0.x * Double(target.width), y: $0.y * Double(target.height))
        }
    }
}

/// Keeps a physical square ROI fully inside a level-0 slide while its center moves.
public enum SquareROIBounds {
    public static func clampedNormalizedCenter(
        x: Double,
        y: Double,
        sideMicrons: Double,
        slide: SlideGeometry,
        micronsPerPixelX: Double,
        micronsPerPixelY: Double
    ) -> PixelPoint {
        let safeMPP_X = max(micronsPerPixelX, .leastNonzeroMagnitude)
        let safeMPP_Y = max(micronsPerPixelY, .leastNonzeroMagnitude)
        let halfX = min(0.5, sideMicrons / safeMPP_X / Double(slide.width) / 2)
        let halfY = min(0.5, sideMicrons / safeMPP_Y / Double(slide.height) / 2)
        return PixelPoint(
            x: min(max(x, halfX), 1 - halfX),
            y: min(max(y, halfY), 1 - halfY)
        )
    }
}
