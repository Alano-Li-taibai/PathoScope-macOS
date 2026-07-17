import AppKit
import Foundation
import PathoScopeCore

struct SquareROIRecord: Identifiable, Equatable {
    let id: UUID
    let slideID: UUID
    var name: String
    var centerX: Double
    var centerY: Double
    var sideMicrons: Double

    init(
        id: UUID = UUID(),
        slideID: UUID,
        name: String,
        centerX: Double,
        centerY: Double,
        sideMicrons: Double
    ) {
        self.id = id
        self.slideID = slideID
        self.name = name
        self.centerX = centerX
        self.centerY = centerY
        self.sideMicrons = sideMicrons
    }

    func pixelRect(descriptor: SlideTileSourceDescriptor) -> CGRect? {
        guard let mppX = descriptor.micronsPerPixelX,
              let mppY = descriptor.micronsPerPixelY,
              mppX > 0,
              mppY > 0 else { return nil }
        let slideWidth = Double(descriptor.levelZeroWidth)
        let slideHeight = Double(descriptor.levelZeroHeight)
        let width = min(slideWidth, max(1, sideMicrons / mppX))
        let height = min(slideHeight, max(1, sideMicrons / mppY))
        let originX = min(max(centerX * slideWidth - width / 2, 0), slideWidth - width)
        let originY = min(max(centerY * slideHeight - height / 2, 0), slideHeight - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

struct ROIAnalysisResult: Identifiable, Equatable {
    let id = UUID()
    let slot: String
    let slideID: UUID
    let slideName: String
    let roiID: UUID
    let roiName: String
    let channelID: String
    let channelName: String
    let sideMicrons: Double
    let backgroundOuterScale: Double
    let statistics: ROIBackgroundCorrectedStatistics

    var areaSquareMicrons: Double {
        sideMicrons * sideMicrons
    }
}

enum ROIAnalysisEngine {
    static let backgroundOuterScale = 1.5

    static func analyze(
        slot: String,
        slide: ImportedSlide,
        roi: SquareROIRecord,
        channelID: String,
        channelName: String,
        session: TileRenderSession
    ) async throws -> ROIAnalysisResult {
        let descriptor = session.descriptor
        guard let channelIndex = descriptor.channels.firstIndex(where: { $0.id == channelID }),
              channelIndex < 4 else {
            throw SlideTileError.invalidData("所选切片没有可定量的独立荧光通道")
        }
        guard let roiRect = roi.pixelRect(descriptor: descriptor),
              let mppX = descriptor.micronsPerPixelX,
              let mppY = descriptor.micronsPerPixelY else {
            throw SlideTileError.invalidData("切片缺少 µm/px 标定，无法创建物理尺寸 ROI")
        }

        let outerWidth = min(
            Double(descriptor.levelZeroWidth),
            roiRect.width * backgroundOuterScale
        )
        let outerHeight = min(
            Double(descriptor.levelZeroHeight),
            roiRect.height * backgroundOuterScale
        )
        let outerX = min(
            max(roiRect.midX - outerWidth / 2, 0),
            Double(descriptor.levelZeroWidth) - outerWidth
        )
        let outerY = min(
            max(roiRect.midY - outerHeight / 2, 0),
            Double(descriptor.levelZeroHeight) - outerHeight
        )
        let outer = CGRect(x: outerX, y: outerY, width: outerWidth, height: outerHeight)
        let sampleX = max(0, Int(floor(outer.minX)))
        let sampleY = max(0, Int(floor(outer.minY)))
        let sampleX1 = min(descriptor.levelZeroWidth, Int(ceil(outer.maxX)))
        let sampleY1 = min(descriptor.levelZeroHeight, Int(ceil(outer.maxY)))
        let sampleWidth = max(1, sampleX1 - sampleX)
        let sampleHeight = max(1, sampleY1 - sampleY)
        let bytes = try await session.rawLevelZeroRegion(
            x: sampleX,
            y: sampleY,
            width: sampleWidth,
            height: sampleHeight
        )

        var roiPixels: [Double] = []
        var backgroundPixels: [Double] = []
        roiPixels.reserveCapacity(Int(roiRect.width * roiRect.height))
        backgroundPixels.reserveCapacity(max(1, sampleWidth * sampleHeight / 2))
        bytes.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for localY in 0..<sampleHeight {
                let worldY = Double(sampleY + localY) + 0.5
                for localX in 0..<sampleWidth {
                    let worldX = Double(sampleX + localX) + 0.5
                    let value = Double(pixels[(localY * sampleWidth + localX) * 4 + channelIndex])
                    if roiRect.contains(CGPoint(x: worldX, y: worldY)) {
                        roiPixels.append(value)
                    } else if outer.contains(CGPoint(x: worldX, y: worldY)) {
                        backgroundPixels.append(value)
                    }
                }
            }
        }

        let statistics = try PixelStatistics.computeBackgroundCorrected(
            roiPixels: roiPixels,
            backgroundPixels: backgroundPixels,
            positiveThreshold: 1,
            pixelAreaSquareMicrons: mppX * mppY
        )
        return ROIAnalysisResult(
            slot: slot,
            slideID: slide.id,
            slideName: slide.displayName,
            roiID: roi.id,
            roiName: roi.name,
            channelID: channelID,
            channelName: channelName,
            sideMicrons: roi.sideMicrons,
            backgroundOuterScale: backgroundOuterScale,
            statistics: statistics
        )
    }
}

enum ROIExportFormat {
    case png
    case tiff

    var pathExtension: String { self == .png ? "png" : "tiff" }
}

enum ROIPublicationRenderer {
    private static let outputPixels = 1600

    @MainActor
    static func render(
        slideName: String,
        roi: SquareROIRecord,
        session: TileRenderSession,
        channelSettings: [ChannelDisplaySettings],
        channelAliases: [String: String],
        format: ROIExportFormat
    ) async throws -> Data {
        let descriptor = session.descriptor
        guard let rect = roi.pixelRect(descriptor: descriptor),
              let mppX = descriptor.micronsPerPixelX else {
            throw SlideTileError.invalidData("切片缺少 µm/px 标定，无法导出带比例尺截图")
        }
        let x = max(0, Int(floor(rect.minX)))
        let y = max(0, Int(floor(rect.minY)))
        let x1 = min(descriptor.levelZeroWidth, Int(ceil(rect.maxX)))
        let y1 = min(descriptor.levelZeroHeight, Int(ceil(rect.maxY)))
        let width = max(1, x1 - x)
        let height = max(1, y1 - y)
        let raw = try await session.rawLevelZeroRegion(x: x, y: y, width: width, height: height)
        let source = try displayImage(
            raw: raw,
            width: width,
            height: height,
            descriptor: descriptor,
            settings: channelSettings
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputPixels,
            height: outputPixels,
            bitsPerComponent: 8,
            bytesPerRow: outputPixels * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SlideTileError.invalidData("无法创建 ROI 导出画布")
        }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: outputPixels, height: outputPixels))
        context.draw(source, in: CGRect(x: 0, y: 0, width: outputPixels, height: outputPixels))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        drawChannelLabels(
            settings: channelSettings,
            aliases: channelAliases,
            canvasWidth: CGFloat(outputPixels),
            canvasHeight: CGFloat(outputPixels)
        )
        drawScaleBar(
            micronsPerImagePixel: mppX,
            sourcePixelWidth: width,
            canvasWidth: CGFloat(outputPixels)
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else {
            throw SlideTileError.invalidData("无法生成 ROI 截图")
        }
        let bitmap = NSBitmapImageRep(cgImage: output)
        bitmap.size = NSSize(
            width: Double(outputPixels) / 600 * 72,
            height: Double(outputPixels) / 600 * 72
        )
        if format == .png {
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw SlideTileError.invalidData("PNG 编码失败")
            }
            return data
        }
        guard let data = bitmap.representation(
            using: .tiff,
            properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw]
        ) else {
            throw SlideTileError.invalidData("TIFF 编码失败")
        }
        return data
    }

    private static func displayImage(
        raw: Data,
        width: Int,
        height: Int,
        descriptor: SlideTileSourceDescriptor,
        settings: [ChannelDisplaySettings]
    ) throws -> CGImage {
        let settingsByID = Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0) })
        let input = [UInt8](raw)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if descriptor.renderMode == .rgb {
                output[offset] = input[offset]
                output[offset + 1] = input[offset + 1]
                output[offset + 2] = input[offset + 2]
                output[offset + 3] = 255
                continue
            }
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            for index in 0..<min(4, descriptor.channels.count) {
                let channel = descriptor.channels[index]
                let setting = settingsByID[channel.id]
                guard setting?.isVisible != false else { continue }
                let black = setting?.black ?? channel.defaultBlack
                let white = max(setting?.white ?? channel.defaultWhite, black + 0.0001)
                let gamma = max(setting?.gamma ?? channel.defaultGamma, 0.05)
                let brightness = setting?.brightness ?? 0
                let contrast = setting?.contrast ?? 1
                var value = (Double(input[offset + index]) / 255 - black) / (white - black)
                value = min(max(value, 0), 1)
                value = pow(value, 1 / gamma)
                value *= pow(2, brightness * 4)
                value = min(max((value - 0.5) * contrast + 0.5, 0), 1)
                red += value * (setting?.red ?? channel.red)
                green += value * (setting?.green ?? channel.green)
                blue += value * (setting?.blue ?? channel.blue)
            }
            output[offset] = UInt8(min(max(red, 0), 1) * 255)
            output[offset + 1] = UInt8(min(max(green, 0), 1) * 255)
            output[offset + 2] = UInt8(min(max(blue, 0), 1) * 255)
            output[offset + 3] = 255
        }
        let data = Data(output)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw SlideTileError.invalidData("ROI 图像编码失败")
        }
        return image
    }

    private static func drawChannelLabels(
        settings: [ChannelDisplaySettings],
        aliases: [String: String],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) {
        let visible = settings.filter(\.isVisible)
        guard !visible.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 44, weight: .semibold)
        let separatorFont = NSFont.systemFont(ofSize: 39, weight: .regular)
        let label = NSMutableAttributedString()
        for (index, channel) in visible.enumerated() {
            if index > 0 {
                label.append(NSAttributedString(
                    string: " + ",
                    attributes: [.font: separatorFont, .foregroundColor: NSColor.white]
                ))
            }
            label.append(NSAttributedString(
                string: aliases[channel.id].flatMap { $0.isEmpty ? nil : $0 } ?? channel.name,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(
                        calibratedRed: channel.red,
                        green: channel.green,
                        blue: channel.blue,
                        alpha: 1
                    ),
                    .strokeColor: NSColor.black.withAlphaComponent(0.8),
                    .strokeWidth: -2.2
                ]
            ))
        }
        let size = label.size()
        let background = NSBezierPath(
            roundedRect: CGRect(
                x: 34,
                y: canvasHeight - size.height - 58,
                width: min(canvasWidth - 68, size.width + 30),
                height: size.height + 22
            ),
            xRadius: 10,
            yRadius: 10
        )
        NSColor.black.withAlphaComponent(0.58).setFill()
        background.fill()
        label.draw(at: CGPoint(x: 49, y: canvasHeight - size.height - 47))
    }

    private static func drawScaleBar(
        micronsPerImagePixel: Double,
        sourcePixelWidth: Int,
        canvasWidth: CGFloat
    ) {
        let scale = Double(canvasWidth) / Double(max(sourcePixelWidth, 1))
        guard let measurement = ScaleBarCalculator.measurement(
            micronsPerImagePixel: micronsPerImagePixel,
            pointsPerImagePixel: scale,
            maximumPoints: Double(canvasWidth * 0.28)
        ) else { return }
        let x: CGFloat = 54
        let y: CGFloat = 63
        let width = CGFloat(measurement.points)
        let path = NSBezierPath()
        path.lineWidth = 6
        path.move(to: CGPoint(x: x, y: y))
        path.line(to: CGPoint(x: x + width, y: y))
        path.move(to: CGPoint(x: x, y: y - 13))
        path.line(to: CGPoint(x: x, y: y + 13))
        path.move(to: CGPoint(x: x + width, y: y - 13))
        path.line(to: CGPoint(x: x + width, y: y + 13))
        NSColor.black.withAlphaComponent(0.75).setStroke()
        let shadow = path.copy() as! NSBezierPath
        shadow.lineWidth = 12
        shadow.stroke()
        NSColor.white.setStroke()
        path.stroke()
        NSAttributedString(
            string: measurement.label,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -2.0
            ]
        ).draw(at: CGPoint(x: x, y: y + 18))
    }

}
