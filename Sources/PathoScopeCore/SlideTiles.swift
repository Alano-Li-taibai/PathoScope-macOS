import Foundation

public enum SlideTileRenderMode: Int, Codable, Sendable {
    case rgb
    case fourChannel
}

public struct SlideTileChannelDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let defaultBlack: Double
    public let defaultWhite: Double
    public let defaultGamma: Double

    public init(
        id: String,
        name: String,
        red: Double,
        green: Double,
        blue: Double,
        defaultBlack: Double = 0,
        defaultWhite: Double = 0.5,
        defaultGamma: Double = 1
    ) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.defaultBlack = defaultBlack
        self.defaultWhite = defaultWhite
        self.defaultGamma = defaultGamma
    }
}

public struct SlideTileLevel: Equatable, Codable, Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let downsample: Double

    public init(index: Int, width: Int, height: Int, downsample: Double) {
        self.index = index
        self.width = width
        self.height = height
        self.downsample = downsample
    }
}

public struct SlideTileSourceDescriptor: Equatable, Codable, Sendable {
    public let fingerprint: String
    public let tileSize: Int
    public let levels: [SlideTileLevel]
    public let micronsPerPixelX: Double?
    public let micronsPerPixelY: Double?
    public let renderMode: SlideTileRenderMode
    public let channels: [SlideTileChannelDescriptor]

    public init(
        fingerprint: String,
        tileSize: Int,
        levels: [SlideTileLevel],
        micronsPerPixelX: Double?,
        micronsPerPixelY: Double?,
        renderMode: SlideTileRenderMode,
        channels: [SlideTileChannelDescriptor]
    ) {
        self.fingerprint = fingerprint
        self.tileSize = tileSize
        self.levels = levels
        self.micronsPerPixelX = micronsPerPixelX
        self.micronsPerPixelY = micronsPerPixelY
        self.renderMode = renderMode
        self.channels = channels
    }

    public var levelZeroWidth: Int { levels.first?.width ?? 0 }
    public var levelZeroHeight: Int { levels.first?.height ?? 0 }
}

public struct SlideTileKey: Hashable, Codable, Sendable {
    public let fingerprint: String
    public let level: Int
    public let column: Int
    public let row: Int

    public init(fingerprint: String, level: Int, column: Int, row: Int) {
        self.fingerprint = fingerprint
        self.level = level
        self.column = column
        self.row = row
    }

    public var cacheIdentifier: String {
        "tile-v5-\(fingerprint)-l\(level)-x\(column)-y\(row)"
    }
}

public struct SlideTileData: Equatable, Sendable {
    public let key: SlideTileKey
    public let width: Int
    public let height: Int
    public let bytes: Data

    public init(key: SlideTileKey, width: Int, height: Int, bytes: Data) {
        self.key = key
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var memoryCost: Int { bytes.count }
}

public protocol SlideTileSource: Sendable {
    var descriptor: SlideTileSourceDescriptor { get }
    func tile(for key: SlideTileKey) async throws -> SlideTileData
}

public struct SlideViewportGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func visibleLevelZeroRect(
        descriptor: SlideTileSourceDescriptor,
        centerX: Double,
        centerY: Double,
        zoom: Double,
        aspectRatio: Double
    ) -> SlideViewportGeometry {
        let sourceWidth = max(Double(descriptor.levelZeroWidth), 1)
        let sourceHeight = max(Double(descriptor.levelZeroHeight), 1)
        let sourceAspect = sourceWidth / sourceHeight
        let requestedAspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : sourceAspect
        let safeZoom = max(zoom, 1)

        let fittingWidth: Double
        let fittingHeight: Double
        if requestedAspect > sourceAspect {
            fittingWidth = sourceWidth
            fittingHeight = sourceWidth / requestedAspect
        } else {
            fittingWidth = sourceHeight * requestedAspect
            fittingHeight = sourceHeight
        }

        let width = min(sourceWidth, max(1, fittingWidth / safeZoom))
        let height = min(sourceHeight, max(1, fittingHeight / safeZoom))
        let clampedCenterX = min(max(centerX, 0), 1)
        let clampedCenterY = min(max(centerY, 0), 1)
        let x = min(max(clampedCenterX * sourceWidth - width / 2, 0), sourceWidth - width)
        let y = min(max(clampedCenterY * sourceHeight - height / 2, 0), sourceHeight - height)
        return SlideViewportGeometry(x: x, y: y, width: width, height: height)
    }

    public static func bestLevel(
        descriptor: SlideTileSourceDescriptor,
        visibleRect: SlideViewportGeometry,
        viewportPixelWidth: Double,
        viewportPixelHeight: Double
    ) -> Int {
        guard !descriptor.levels.isEmpty else { return 0 }
        let desiredX = visibleRect.width / max(viewportPixelWidth, 1)
        let desiredY = visibleRect.height / max(viewportPixelHeight, 1)
        let desiredDownsample = max(desiredX, desiredY, 1)
        return descriptor.levels
            .filter { $0.downsample <= desiredDownsample * 1.15 }
            .max(by: { $0.downsample < $1.downsample })?
            .index ?? descriptor.levels.first!.index
    }
}

public enum SlideTileError: Error, LocalizedError, Equatable {
    case invalidKey
    case invalidData(String)
    case helperUnavailable(String)
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "瓦片坐标无效"
        case .invalidData(let detail):
            return "瓦片数据无效：\(detail)"
        case .helperUnavailable(let detail):
            return "OpenSlide 瓦片读取组件不可用：\(detail)"
        case .helperFailed(let detail):
            return "OpenSlide 瓦片读取失败：\(detail)"
        }
    }
}
