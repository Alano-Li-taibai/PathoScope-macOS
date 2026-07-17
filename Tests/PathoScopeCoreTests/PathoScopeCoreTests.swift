import Testing
import Foundation
import AppKit
@testable import PathoScopeCore

@Test func copiesROIUsingNormalizedLevelZeroCoordinates() throws {
    let source = try SlideGeometry(width: 1000, height: 500)
    let target = try SlideGeometry(width: 2000, height: 1000)
    let roi = try NormalizedROI(
        name: "ROI A",
        shape: .rectangle,
        pixelPoints: [PixelPoint(x: 100, y: 50), PixelPoint(x: 400, y: 250)],
        source: source
    )

    #expect(roi.pixelPoints(on: target) == [
        PixelPoint(x: 200, y: 100),
        PixelPoint(x: 800, y: 500)
    ])
}

@Test func clampsMovedPhysicalSquareROIInsideSlideBounds() throws {
    let slide = try SlideGeometry(width: 1_000, height: 500)
    let center = SquareROIBounds.clampedNormalizedCenter(
        x: 0.99,
        y: -0.2,
        sideMicrons: 100,
        slide: slide,
        micronsPerPixelX: 0.5,
        micronsPerPixelY: 0.5
    )

    #expect(center == PixelPoint(x: 0.9, y: 0.2))
}

@Test func computesRequestedROIStatistics() throws {
    let result = try PixelStatistics.compute(
        pixels: [0, 2, 4, 6],
        positiveThreshold: 4,
        pixelAreaSquareMicrons: 0.25
    )

    #expect(result.pixelCount == 4)
    #expect(result.mean == 3)
    #expect(result.median == 3)
    #expect(result.integratedIntensity == 3)
    #expect(result.positiveAreaFraction == 0.5)
}

@Test func rejectsEmptyPixelSet() {
    #expect(throws: StatisticsError.emptyPixels) {
        try PixelStatistics.compute(pixels: [], positiveThreshold: 1)
    }
}

@Test func computesBackgroundCorrectedMeanFromRawPixels() throws {
    let result = try PixelStatistics.computeBackgroundCorrected(
        roiPixels: [10, 14, 18, 22],
        backgroundPixels: [2, 4, 6, 8],
        positiveThreshold: 12,
        pixelAreaSquareMicrons: 0.25
    )

    #expect(result.raw.mean == 16)
    #expect(result.raw.median == 16)
    #expect(result.backgroundMean == 5)
    #expect(result.backgroundCorrectedMean == 11)
    #expect(result.backgroundPixelCount == 4)
}

@Test func detectsSupportedSlideFormats() {
    #expect(SlideFormat.detect(filename: "slide.MRXS") == .mrxs)
    #expect(SlideFormat.detect(filename: "slide.svs") == .svs)
    #expect(SlideFormat.detect(filename: "slide.ome.tiff") == .omeTiff)
    #expect(SlideFormat.detect(filename: "notes.pdf") == nil)
}

@Test func automaticallyLinksCompleteMRXSPackage() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let main = root.appendingPathComponent("sample.mrxs")
    let companion = root.appendingPathComponent("sample")
    try fm.createDirectory(at: companion, withIntermediateDirectories: true)
    #expect(fm.createFile(atPath: main.path, contents: Data()))
    #expect(fm.createFile(atPath: companion.appendingPathComponent("Index.dat").path, contents: Data()))
    #expect(fm.createFile(atPath: companion.appendingPathComponent("Slidedat.ini").path, contents: Data()))
    #expect(fm.createFile(atPath: companion.appendingPathComponent("Data0000.dat").path, contents: Data()))
    defer { try? fm.removeItem(at: root) }

    let slide = try SlideImportService().inspect(main)
    #expect(slide.format == .mrxs)
    #expect(slide.companionDirectoryURL == companion)
}

@Test func reportsMissingMRXSCompanionDirectory() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let main = root.appendingPathComponent("sample.mrxs")
    #expect(fm.createFile(atPath: main.path, contents: Data()))
    defer { try? fm.removeItem(at: root) }

    #expect(throws: SlideImportError.missingMRXSCompanionDirectory("sample")) {
        try SlideImportService().inspect(main)
    }
}

@Test func parsesPyramidMetadataAndSelectsBoundedPreviewLevel() throws {
    let properties = """
    openslide.level-count: '3'
    openslide.level[0].width: '10000'
    openslide.level[0].height: '20000'
    openslide.level[0].downsample: '1'
    openslide.level[1].width: '5000'
    openslide.level[1].height: '10000'
    openslide.level[1].downsample: '2'
    openslide.level[2].width: '2500'
    openslide.level[2].height: '5000'
    openslide.level[2].downsample: '4'
    openslide.bounds-x: '100'
    openslide.bounds-y: '200'
    openslide.bounds-width: '4000'
    openslide.bounds-height: '8000'
    """
    let metadata = try SlidePyramidMetadata.parse(properties: properties)
    let region = try metadata.previewRegion(maxDimension: 2400)
    #expect(region.x == 100)
    #expect(region.y == 200)
    #expect(region.level == 2)
    #expect(region.width == 1000)
    #expect(region.height == 2000)
}

@Test func selectsFullSlidePreviewWhenBoundsAreAbsent() throws {
    let properties = """
    openslide.level-count: '2'
    openslide.level[0].width: '8000'
    openslide.level[0].height: '6000'
    openslide.level[0].downsample: '1'
    openslide.level[1].width: '2000'
    openslide.level[1].height: '1500'
    openslide.level[1].downsample: '4'
    """
    let region = try SlidePyramidMetadata.parse(properties: properties)
        .previewRegion(maxDimension: 2400)
    #expect(region.level == 1)
    #expect(region.width == 2000)
    #expect(region.height == 1500)
}

@Test func zoomedViewportSelectsHigherResolutionRegion() throws {
    let properties = """
    openslide.level-count: '3'
    openslide.level[0].width: '10000'
    openslide.level[0].height: '20000'
    openslide.level[0].downsample: '1'
    openslide.level[1].width: '5000'
    openslide.level[1].height: '10000'
    openslide.level[1].downsample: '2'
    openslide.level[2].width: '2500'
    openslide.level[2].height: '5000'
    openslide.level[2].downsample: '4'
    openslide.bounds-x: '100'
    openslide.bounds-y: '200'
    openslide.bounds-width: '4000'
    openslide.bounds-height: '8000'
    openslide.mpp-x: '0.2738'
    openslide.mpp-y: '0.2738'
    """
    let metadata = try SlidePyramidMetadata.parse(properties: properties)
    let region = try metadata.viewportRegion(
        SlideViewportRequest(centerX: 0.5, centerY: 0.5, zoom: 4, maxDimension: 2400)
    )
    #expect(region.level == 0)
    #expect(region.x == 1600)
    #expect(region.y == 3200)
    #expect(region.width == 1000)
    #expect(region.height == 2000)
    #expect(metadata.micronsPerPixelX == 0.2738)
}

@Test func viewportAspectRatioCropsRegionForFillDisplay() throws {
    let properties = """
    openslide.level-count: '3'
    openslide.level[0].width: '4000'
    openslide.level[0].height: '4000'
    openslide.level[0].downsample: '1'
    openslide.level[1].width: '2000'
    openslide.level[1].height: '2000'
    openslide.level[1].downsample: '2'
    openslide.level[2].width: '1000'
    openslide.level[2].height: '1000'
    openslide.level[2].downsample: '4'
    """
    let metadata = try SlidePyramidMetadata.parse(properties: properties)
    let region = try metadata.viewportRegion(
        SlideViewportRequest(centerX: 0.5, centerY: 0.5, zoom: 1, maxDimension: 4096, aspectRatio: 2)
    )
    #expect(region.level == 0)
    #expect(region.x == 0)
    #expect(region.y == 1000)
    #expect(region.width == 4000)
    #expect(region.height == 2000)
}

@Test func tileViewportGeometryFillsRequestedAspect() {
    let descriptor = SlideTileSourceDescriptor(
        fingerprint: "test",
        tileSize: 512,
        levels: [
            SlideTileLevel(index: 0, width: 4000, height: 4000, downsample: 1)
        ],
        micronsPerPixelX: 0.25,
        micronsPerPixelY: 0.25,
        renderMode: .rgb,
        channels: []
    )
    let rect = SlideViewportGeometry.visibleLevelZeroRect(
        descriptor: descriptor,
        centerX: 0.5,
        centerY: 0.5,
        zoom: 1,
        aspectRatio: 2
    )
    #expect(rect.x == 0)
    #expect(rect.y == 1000)
    #expect(rect.width == 4000)
    #expect(rect.height == 2000)
}

@Test func detectsPairedSVSPyramidLevels() throws {
    let properties = """
    openslide.level-count: '4'
    openslide.level[0].width: '8000'
    openslide.level[0].height: '6000'
    openslide.level[0].downsample: '1'
    openslide.level[1].width: '8000'
    openslide.level[1].height: '6000'
    openslide.level[1].downsample: '1'
    openslide.level[2].width: '2000'
    openslide.level[2].height: '1500'
    openslide.level[2].downsample: '4'
    openslide.level[3].width: '2000'
    openslide.level[3].height: '1500'
    openslide.level[3].downsample: '4'
    """
    let metadata = try SlidePyramidMetadata.parse(properties: properties)
    #expect(metadata.pairedLevel(after: 0) == 1)
    #expect(metadata.pairedLevel(after: 2) == 3)
    #expect(metadata.pairedLevel(after: 1) == nil)
}

@Test func choosesReadableOneTwoFiveScaleBar() throws {
    let measurement = try #require(ScaleBarCalculator.measurement(
        micronsPerImagePixel: 0.5,
        pointsPerImagePixel: 2,
        maximumPoints: 120
    ))
    #expect(measurement.microns == 20)
    #expect(measurement.points == 80)
    #expect(measurement.label == "20 µm")
}

@Test func decodesMRXSImageRowsWithoutVerticalFlip() throws {
    let sourcePixels = Data([
        255, 0, 0, 255,
        0, 0, 255, 255
    ])
    let provider = try #require(CGDataProvider(data: sourcePixels as CFData))
    let image = try #require(CGImage(
        width: 1,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let bitmap = NSBitmapImageRep(cgImage: image)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let decoded = try #require(MRXSNativeReader.decodeRGBA(png))

    #expect(decoded.width == 1)
    #expect(decoded.height == 2)
    #expect(decoded.pixels[0] > 240)
    #expect(decoded.pixels[1] < 15)
    #expect(decoded.pixels[2] < 15)
    #expect(decoded.pixels[4] < 15)
    #expect(decoded.pixels[5] < 15)
    #expect(decoded.pixels[6] > 240)
}

@Test func validatesRealMRXSTileSourceWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["PATHOSCOPE_REAL_MRXS"] else { return }
    let source = try MRXSTileSource(slideURL: URL(fileURLWithPath: sourcePath))
    let descriptor = source.descriptor

    #expect(descriptor.tileSize == 512)
    #expect(descriptor.renderMode == .fourChannel)
    #expect(Set(descriptor.channels.map(\.name)) == Set(["DAPI", "SPorange", "SpGreen", "CY5"]))
    #expect(descriptor.levelZeroWidth > 20_000)
    #expect(descriptor.levelZeroHeight > 30_000)

    let lowestLevel = try #require(descriptor.levels.last)
    let tile = try await source.tile(for: SlideTileKey(
        fingerprint: descriptor.fingerprint,
        level: lowestLevel.index,
        column: 0,
        row: 0
    ))
    #expect(tile.bytes.count == 512 * 512 * 4)
    let bytes = [UInt8](tile.bytes)
    let maxima = (0..<4).map { component in
        stride(from: component, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0
    }
    #expect(maxima[0] > 0)
    #expect(maxima[1] > 0)
    #expect(maxima[2] > 0)
    #expect(maxima[3] > 0)
}

@Test func writesRealMRXSTileMosaicWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["PATHOSCOPE_REAL_MRXS"],
          let outputPath = environment["PATHOSCOPE_TILE_VALIDATION_DIR"] else { return }
    let source = try MRXSTileSource(slideURL: URL(fileURLWithPath: sourcePath))
    let descriptor = source.descriptor
    let requestedLevel = Int(environment["PATHOSCOPE_TILE_VALIDATION_LEVEL"] ?? "4") ?? 4
    let level = try #require(descriptor.levels.first(where: { $0.index == requestedLevel }))
    var output = [UInt8](repeating: 0, count: level.width * level.height * 4)
    let columns = Int(ceil(Double(level.width) / Double(descriptor.tileSize)))
    let rows = Int(ceil(Double(level.height) / Double(descriptor.tileSize)))

    for row in 0..<rows {
        for column in 0..<columns {
            let tile = try await source.tile(for: SlideTileKey(
                fingerprint: descriptor.fingerprint,
                level: level.index,
                column: column,
                row: row
            ))
            let sourceBytes = [UInt8](tile.bytes)
            let copyWidth = min(descriptor.tileSize, level.width - column * descriptor.tileSize)
            let copyHeight = min(descriptor.tileSize, level.height - row * descriptor.tileSize)
            for y in 0..<copyHeight {
                for x in 0..<copyWidth {
                    let sourceOffset = (y * descriptor.tileSize + x) * 4
                    let destinationX = column * descriptor.tileSize + x
                    let destinationY = row * descriptor.tileSize + y
                    let destinationOffset = (destinationY * level.width + destinationX) * 4
                    let dapi = Int(sourceBytes[sourceOffset])
                    let orange = Int(sourceBytes[sourceOffset + 1])
                    let green = Int(sourceBytes[sourceOffset + 2])
                    let cy5 = Int(sourceBytes[sourceOffset + 3])
                    output[destinationOffset] = UInt8(min(255, orange * 2 + cy5 * 2))
                    output[destinationOffset + 1] = UInt8(min(255, green * 2 + cy5 * 2))
                    output[destinationOffset + 2] = UInt8(min(255, dapi * 2))
                    output[destinationOffset + 3] = 255
                }
            }
        }
    }

    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: level.width,
        pixelsHigh: level.height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: level.width * 4,
        bitsPerPixel: 32
    ))
    memcpy(bitmap.bitmapData, output, output.count)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try png.write(
        to: outputDirectory.appendingPathComponent(
            "MRXS_native_tile_mosaic_level\(level.index).png"
        )
    )
}

@Test func validatesRealOpenSlideTileSourceWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["PATHOSCOPE_REAL_SVS"],
          let helperPath = environment["PATHOSCOPE_OPENSLIDE_TILE_HELPER"] else { return }
    let slide = ImportedSlide(
        sourceURL: URL(fileURLWithPath: sourcePath),
        format: .svs
    )
    let source = try OpenSlideTileSource(
        slide: slide,
        helperURL: URL(fileURLWithPath: helperPath),
        workerCount: 1
    )
    let descriptor = source.descriptor
    #expect(descriptor.renderMode == .fourChannel)
    #expect(descriptor.levels.count == 8)
    #expect(descriptor.channels.count == 4)

    let lowestLevel = try #require(descriptor.levels.last)
    let tile = try await source.tile(for: SlideTileKey(
        fingerprint: descriptor.fingerprint,
        level: lowestLevel.index,
        column: 0,
        row: 0
    ))
    #expect(tile.bytes.count == 512 * 512 * 4)
    #expect([UInt8](tile.bytes).contains(where: { $0 > 0 }))
}
