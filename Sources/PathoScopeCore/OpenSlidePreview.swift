import Foundation

public struct SlideLevel: Equatable, Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let downsample: Double
}

public struct SlideViewportRequest: Equatable, Sendable {
    public let centerX: Double
    public let centerY: Double
    public let zoom: Double
    public let maxDimension: Int
    public let aspectRatio: Double?

    public init(
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        zoom: Double = 1,
        maxDimension: Int = 2400,
        aspectRatio: Double? = nil
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
        self.maxDimension = maxDimension
        self.aspectRatio = aspectRatio
    }
}

public struct SlidePyramidMetadata: Equatable, Sendable {
    public let levels: [SlideLevel]
    public let boundsX: Int?
    public let boundsY: Int?
    public let boundsWidth: Int?
    public let boundsHeight: Int?
    public let micronsPerPixelX: Double?
    public let micronsPerPixelY: Double?

    public static func parse(properties text: String) throws -> SlidePyramidMetadata {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }

        guard let levelCountText = values["openslide.level-count"],
              let levelCount = Int(levelCountText), levelCount > 0 else {
            throw OpenSlidePreviewError.invalidMetadata("未找到有效的金字塔层级")
        }

        var levels: [SlideLevel] = []
        for index in 0..<levelCount {
            guard let width = Int(values["openslide.level[\(index)].width"] ?? ""),
                  let height = Int(values["openslide.level[\(index)].height"] ?? ""),
                  let downsample = Double(values["openslide.level[\(index)].downsample"] ?? "") else {
                throw OpenSlidePreviewError.invalidMetadata("第 \(index) 层信息不完整")
            }
            levels.append(SlideLevel(index: index, width: width, height: height, downsample: downsample))
        }

        return SlidePyramidMetadata(
            levels: levels,
            boundsX: Int(values["openslide.bounds-x"] ?? ""),
            boundsY: Int(values["openslide.bounds-y"] ?? ""),
            boundsWidth: Int(values["openslide.bounds-width"] ?? ""),
            boundsHeight: Int(values["openslide.bounds-height"] ?? ""),
            micronsPerPixelX: Double(values["openslide.mpp-x"] ?? ""),
            micronsPerPixelY: Double(values["openslide.mpp-y"] ?? "")
        )
    }

    public func previewRegion(maxDimension: Int = 2400) throws -> PreviewRegion {
        try viewportRegion(SlideViewportRequest(maxDimension: maxDimension))
    }

    public func viewportRegion(_ request: SlideViewportRequest) throws -> PreviewRegion {
        guard request.maxDimension > 0, request.zoom >= 1, let base = levels.first else {
            throw OpenSlidePreviewError.invalidMetadata("预览尺寸无效")
        }

        let hasBounds = boundsX != nil && boundsY != nil && boundsWidth != nil && boundsHeight != nil
        let sourceWidth = hasBounds ? boundsWidth! : base.width
        let sourceHeight = hasBounds ? boundsHeight! : base.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw OpenSlidePreviewError.invalidMetadata("切片尺寸无效")
        }

        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let requestedAspect = request.aspectRatio.flatMap { value -> Double? in
            guard value.isFinite, value > 0 else { return nil }
            return value
        }

        let fittingWidth: Double
        let fittingHeight: Double
        if let requestedAspect {
            if requestedAspect > sourceAspect {
                fittingWidth = Double(sourceWidth)
                fittingHeight = Double(sourceWidth) / requestedAspect
            } else {
                fittingWidth = Double(sourceHeight) * requestedAspect
                fittingHeight = Double(sourceHeight)
            }
        } else {
            fittingWidth = Double(sourceWidth)
            fittingHeight = Double(sourceHeight)
        }

        let cropWidth = max(1, min(sourceWidth, Int((fittingWidth / request.zoom).rounded())))
        let cropHeight = max(1, min(sourceHeight, Int((fittingHeight / request.zoom).rounded())))
        let centerX = min(max(request.centerX, 0), 1)
        let centerY = min(max(request.centerY, 0), 1)
        let relativeX = min(max(Int((centerX * Double(sourceWidth) - Double(cropWidth) / 2).rounded()), 0), sourceWidth - cropWidth)
        let relativeY = min(max(Int((centerY * Double(sourceHeight) - Double(cropHeight) / 2).rounded()), 0), sourceHeight - cropHeight)

        let selected = levels.first { level in
            let width = Int(ceil(Double(cropWidth) / level.downsample))
            let height = Int(ceil(Double(cropHeight) / level.downsample))
            return max(width, height) <= request.maxDimension
        } ?? levels.last!

        return PreviewRegion(
            x: (hasBounds ? boundsX! : 0) + relativeX,
            y: (hasBounds ? boundsY! : 0) + relativeY,
            level: selected.index,
            width: max(1, Int(ceil(Double(cropWidth) / selected.downsample))),
            height: max(1, Int(ceil(Double(cropHeight) / selected.downsample))),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            downsample: selected.downsample,
            centerX: centerX,
            centerY: centerY,
            viewportZoom: request.zoom
        )
    }

    public func pairedLevel(after level: Int) -> Int? {
        guard let current = levels.first(where: { $0.index == level }),
              let next = levels.first(where: { $0.index == level + 1 }),
              current.width == next.width,
              current.height == next.height,
              abs(current.downsample - next.downsample) < 0.0001 else { return nil }
        return next.index
    }
}

public struct PreviewRegion: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let level: Int
    public let width: Int
    public let height: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let downsample: Double
    public let centerX: Double
    public let centerY: Double
    public let viewportZoom: Double
}

public enum OpenSlidePreviewError: Error, LocalizedError, Equatable {
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let detail): return "切片元数据无效：\(detail)"
        }
    }
}
