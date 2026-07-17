import CZlib
import Foundation

private struct MRXSLevelLayout: Sendable {
    let imageConcat: Int
    let tilesPerImage: Int
    let tileWidth: Double
    let tileHeight: Double
    let downsample: Double
}

private struct MRXSStagePosition: Sendable {
    let x: Int
    let y: Int
}

private struct MRXSIndexedPlacement: Sendable {
    let x: Double
    let y: Double
    let sourceX: Double
    let sourceY: Double
    let width: Double
    let height: Double
    let entries: [MRXSTileEntry?]
}

private struct MRXSDecodedImage: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

private struct MRXSImageCacheKey: Hashable, Sendable {
    let fileNumber: Int
    let offset: Int
    let size: Int
}

public actor MRXSTileSource: SlideTileSource {
    public nonisolated let descriptor: SlideTileSourceDescriptor

    private let slideDirectory: URL
    private let metadata: MRXSMetadata
    private let tileSize: Int
    private let placementsByLevel: [[Int64: [MRXSIndexedPlacement]]]
    private let channelMappings: [[(output: Int, source: Int)]]
    private var mappedFiles: [Int: Data] = [:]
    private var decodedImages: [MRXSImageCacheKey: (image: MRXSDecodedImage, access: UInt64)] = [:]
    private var accessClock: UInt64 = 0

    public init(slideURL: URL, tileSize: Int = 512) throws {
        let slideDirectory = slideURL.deletingPathExtension()
        let metadata = try MRXSMetadata.parse(
            slideDirectory.appendingPathComponent("Slidedat.ini")
        )
        let indexData = try Data(
            contentsOf: slideDirectory.appendingPathComponent("Index.dat"),
            options: .mappedIfSafe
        )
        let rootOffset = 5 + metadata.slideID.utf8.count
        let hierarchicalTableBase = try MRXSNativeReader.readInt32(indexData, at: rootOffset)
        let stagePositions = try Self.readStagePositions(
            metadata: metadata,
            indexData: indexData,
            slideDirectory: slideDirectory,
            nonhierarchicalRoot: rootOffset + 4
        )
        let layouts = try Self.makeLayouts(metadata: metadata)

        var entriesByLevelAndFilter: [[[Int: MRXSTileEntry]]] = []
        for level in 0..<metadata.zoomLevels {
            var filters: [[Int: MRXSTileEntry]] = []
            for filterIndex in metadata.dataFilterLevels.indices {
                let entries = try Self.tileEntries(
                    indexData: indexData,
                    hierarchicalTableBase: hierarchicalTableBase,
                    recordIndex: filterIndex * metadata.zoomLevels + level
                )
                filters.append(Dictionary(uniqueKeysWithValues: entries.map { ($0.imageIndex, $0) }))
            }
            entriesByLevelAndFilter.append(filters)
        }

        let activePositions = Self.activeCameraPositions(
            entries: Array(entriesByLevelAndFilter[0][0].values),
            metadata: metadata,
            stagePositions: stagePositions,
            levelZeroImageConcat: layouts[0].imageConcat
        )
        let rawPlacements = try Self.makePlacements(
            metadata: metadata,
            layouts: layouts,
            stagePositions: stagePositions,
            activePositions: activePositions,
            entriesByLevelAndFilter: entriesByLevelAndFilter
        )
        guard let levelZeroBounds = Self.bounds(of: rawPlacements[0]) else {
            throw SlideTileError.invalidData("MRXS 没有可显示的原生瓦片")
        }

        let boundedWidth = max(1, Int(ceil(levelZeroBounds.maxX - levelZeroBounds.minX)))
        let boundedHeight = max(1, Int(ceil(levelZeroBounds.maxY - levelZeroBounds.minY)))
        let safeTileSize = tileSize == 256 ? 256 : 512
        var indexedLevels: [[Int64: [MRXSIndexedPlacement]]] = []
        for level in rawPlacements.indices {
            let downsample = layouts[level].downsample
            let originX = levelZeroBounds.minX / downsample
            let originY = levelZeroBounds.minY / downsample
            var index: [Int64: [MRXSIndexedPlacement]] = [:]
            for placement in rawPlacements[level] {
                let bounded = MRXSIndexedPlacement(
                    x: placement.x - originX,
                    y: placement.y - originY,
                    sourceX: placement.sourceX,
                    sourceY: placement.sourceY,
                    width: placement.width,
                    height: placement.height,
                    entries: placement.entries
                )
                let minimumColumn = max(0, Int(floor(bounded.x / Double(safeTileSize))))
                let maximumColumn = max(
                    minimumColumn,
                    Int(floor((bounded.x + bounded.width - 0.000_001) / Double(safeTileSize)))
                )
                let minimumRow = max(0, Int(floor(bounded.y / Double(safeTileSize))))
                let maximumRow = max(
                    minimumRow,
                    Int(floor((bounded.y + bounded.height - 0.000_001) / Double(safeTileSize)))
                )
                for row in minimumRow...maximumRow {
                    for column in minimumColumn...maximumColumn {
                        index[Self.spatialKey(column: column, row: row), default: []].append(bounded)
                    }
                }
            }
            indexedLevels.append(index)
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: slideDirectory.appendingPathComponent("Index.dat").path
        )
        let indexSize = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(indexData.count)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = "\(metadata.slideID)-\(indexSize)-\(Int64(modified))-mrxs-v5"
        let levels = layouts.indices.map { level in
            SlideTileLevel(
                index: level,
                width: max(1, Int(ceil(Double(boundedWidth) / layouts[level].downsample))),
                height: max(1, Int(ceil(Double(boundedHeight) / layouts[level].downsample))),
                downsample: layouts[level].downsample
            )
        }
        let channels = metadata.channels.prefix(4).map {
            SlideTileChannelDescriptor(
                id: $0.id,
                name: $0.name,
                red: Double($0.red) / 255,
                green: Double($0.green) / 255,
                blue: Double($0.blue) / 255,
                defaultBlack: 0,
                defaultWhite: 0.5,
                defaultGamma: 1
            )
        }
        var channelMappings = Array(
            repeating: [(output: Int, source: Int)](),
            count: metadata.dataFilterLevels.count
        )
        for (output, channel) in metadata.channels.prefix(4).enumerated() {
            guard let filter = metadata.dataFilterLevels.firstIndex(of: channel.dataFilterLevel) else {
                continue
            }
            // STORING_CHANNEL_NUMBER is BGR, while ImageIO returns RGB.
            channelMappings[filter].append((output, 2 - channel.storingChannel))
        }

        self.slideDirectory = slideDirectory
        self.metadata = metadata
        self.tileSize = safeTileSize
        self.placementsByLevel = indexedLevels
        self.channelMappings = channelMappings
        self.descriptor = SlideTileSourceDescriptor(
            fingerprint: fingerprint,
            tileSize: safeTileSize,
            levels: levels,
            micronsPerPixelX: metadata.micronsPerPixel.first,
            micronsPerPixelY: metadata.micronsPerPixel.first,
            renderMode: .fourChannel,
            channels: channels
        )
    }

    public func tile(for key: SlideTileKey) async throws -> SlideTileData {
        try Task.checkCancellation()
        guard key.fingerprint == descriptor.fingerprint,
              key.level >= 0,
              key.level < descriptor.levels.count,
              key.column >= 0,
              key.row >= 0 else {
            throw SlideTileError.invalidKey
        }
        let level = descriptor.levels[key.level]
        guard key.column * tileSize < level.width,
              key.row * tileSize < level.height else {
            throw SlideTileError.invalidKey
        }

        let tileOriginX = key.column * tileSize
        let tileOriginY = key.row * tileSize
        var output = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let placements = placementsByLevel[key.level][
            Self.spatialKey(column: key.column, row: key.row)
        ] ?? []

        for placement in placements {
            try Task.checkCancellation()
            for filterIndex in channelMappings.indices {
                guard !channelMappings[filterIndex].isEmpty,
                      filterIndex < placement.entries.count,
                      let entry = placement.entries[filterIndex] else { continue }
                let decoded = try decodedImage(for: entry)
                Self.blit(
                    decoded,
                    placement: placement,
                    mappings: channelMappings[filterIndex],
                    fillColor: metadata.fillColorRGB,
                    tileOriginX: tileOriginX,
                    tileOriginY: tileOriginY,
                    tileSize: tileSize,
                    output: &output
                )
            }
        }

        return SlideTileData(
            key: key,
            width: tileSize,
            height: tileSize,
            bytes: Data(output)
        )
    }

    private func decodedImage(for entry: MRXSTileEntry) throws -> MRXSDecodedImage {
        let key = MRXSImageCacheKey(
            fileNumber: entry.fileNumber,
            offset: entry.offset,
            size: entry.size
        )
        accessClock &+= 1
        if var cached = decodedImages[key] {
            cached.access = accessClock
            decodedImages[key] = cached
            return cached.image
        }

        guard entry.fileNumber >= 0, entry.fileNumber < metadata.dataFiles.count else {
            throw SlideTileError.invalidData("MRXS Data 文件编号越界")
        }
        let fileData: Data
        if let mapped = mappedFiles[entry.fileNumber] {
            fileData = mapped
        } else {
            let mapped = try Data(
                contentsOf: slideDirectory.appendingPathComponent(metadata.dataFiles[entry.fileNumber]),
                options: .mappedIfSafe
            )
            mappedFiles[entry.fileNumber] = mapped
            fileData = mapped
        }
        guard entry.offset >= 0,
              entry.size > 0,
              entry.offset + entry.size <= fileData.count else {
            throw SlideTileError.invalidData("MRXS JPEG 指针越界")
        }
        let jpeg = fileData.subdata(in: entry.offset..<(entry.offset + entry.size))
        guard let decoded = MRXSNativeReader.decodeRGBA(jpeg) else {
            throw SlideTileError.invalidData("MRXS JPEG 解码失败")
        }
        let image = MRXSDecodedImage(
            width: decoded.width,
            height: decoded.height,
            pixels: decoded.pixels
        )
        decodedImages[key] = (image, accessClock)
        if decodedImages.count > 160,
           let oldest = decodedImages.min(by: { $0.value.access < $1.value.access })?.key {
            decodedImages.removeValue(forKey: oldest)
        }
        return image
    }

    private static func makeLayouts(metadata: MRXSMetadata) throws -> [MRXSLevelLayout] {
        var layouts: [MRXSLevelLayout] = []
        var totalConcatExponent = 0
        var firstImageConcat = 1
        for level in 0..<metadata.zoomLevels {
            totalConcatExponent += metadata.concatExponents[level]
            guard totalConcatExponent >= 0, totalConcatExponent < 30 else {
                throw SlideTileError.invalidData("MRXS IMAGE_CONCAT_FACTOR 无效")
            }
            let imageConcat = 1 << totalConcatExponent
            if level == 0 { firstImageConcat = imageConcat }
            let positionsPerImage = max(1, imageConcat / metadata.imageDivisions)
            let tilesPerImage = positionsPerImage
            layouts.append(MRXSLevelLayout(
                imageConcat: imageConcat,
                tilesPerImage: tilesPerImage,
                tileWidth: Double(metadata.tileWidths[level]) / Double(tilesPerImage),
                tileHeight: Double(metadata.tileHeights[level]) / Double(tilesPerImage),
                downsample: Double(imageConcat) / Double(firstImageConcat)
            ))
        }
        return layouts
    }

    private static func activeCameraPositions(
        entries: [MRXSTileEntry],
        metadata: MRXSMetadata,
        stagePositions: [MRXSStagePosition],
        levelZeroImageConcat: Int
    ) -> Set<Int> {
        var result: Set<Int> = []
        for entry in entries {
            let x = entry.imageIndex % metadata.tileCountX
            let y = entry.imageIndex / metadata.tileCountX
            let positionX = x / metadata.imageDivisions
            let positionY = y / metadata.imageDivisions
            let index = positionY * (metadata.tileCountX / metadata.imageDivisions) + positionX
            guard index >= 0, index < stagePositions.count else { continue }
            let position = stagePositions[index]
            if position.x == 0, position.y == 0, positionX != 0 || positionY != 0 {
                continue
            }
            if x % levelZeroImageConcat == 0, y % levelZeroImageConcat == 0 {
                result.insert(index)
            }
        }
        return result
    }

    private static func makePlacements(
        metadata: MRXSMetadata,
        layouts: [MRXSLevelLayout],
        stagePositions: [MRXSStagePosition],
        activePositions: Set<Int>,
        entriesByLevelAndFilter: [[[Int: MRXSTileEntry]]]
    ) throws -> [[MRXSIndexedPlacement]] {
        var result: [[MRXSIndexedPlacement]] = []
        let positionsAcross = metadata.tileCountX / metadata.imageDivisions
        for level in 0..<metadata.zoomLevels {
            let layout = layouts[level]
            var placements: [MRXSIndexedPlacement] = []
            for entry in entriesByLevelAndFilter[level][0].values {
                let x = entry.imageIndex % metadata.tileCountX
                let y = entry.imageIndex / metadata.tileCountX
                guard y < metadata.tileCountY,
                      x % layout.imageConcat == 0,
                      y % layout.imageConcat == 0 else { continue }

                for tileY in 0..<layout.tilesPerImage {
                    let sourceGridY = y + tileY * metadata.imageDivisions
                    guard sourceGridY < metadata.tileCountY else { break }
                    for tileX in 0..<layout.tilesPerImage {
                        let sourceGridX = x + tileX * metadata.imageDivisions
                        guard sourceGridX < metadata.tileCountX else { break }
                        let cameraX = sourceGridX / metadata.imageDivisions
                        let cameraY = sourceGridY / metadata.imageDivisions
                        let cameraIndex = cameraY * positionsAcross + cameraX
                        guard cameraIndex >= 0,
                              cameraIndex < stagePositions.count,
                              activePositions.contains(cameraIndex) else { continue }
                        let position = stagePositions[cameraIndex]
                        let positionZeroX = position.x
                            + metadata.tileWidths[0] * (
                                sourceGridX - cameraX * metadata.imageDivisions
                            )
                        let positionZeroY = position.y
                            + metadata.tileHeights[0] * (
                                sourceGridY - cameraY * metadata.imageDivisions
                            )
                        let imageEntries = entriesByLevelAndFilter[level].map { $0[entry.imageIndex] }
                        placements.append(MRXSIndexedPlacement(
                            x: Double(positionZeroX) / Double(layout.imageConcat),
                            y: Double(positionZeroY) / Double(layout.imageConcat),
                            sourceX: layout.tileWidth * Double(tileX),
                            sourceY: layout.tileHeight * Double(tileY),
                            width: layout.tileWidth,
                            height: layout.tileHeight,
                            entries: imageEntries
                        ))
                    }
                }
            }
            result.append(placements)
        }
        return result
    }

    private static func bounds(
        of placements: [MRXSIndexedPlacement]
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let first = placements.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for placement in placements.dropFirst() {
            minX = min(minX, placement.x)
            minY = min(minY, placement.y)
            maxX = max(maxX, placement.x + placement.width)
            maxY = max(maxY, placement.y + placement.height)
        }
        return (floor(minX), floor(minY), ceil(maxX), ceil(maxY))
    }

    private static func blit(
        _ decoded: MRXSDecodedImage,
        placement: MRXSIndexedPlacement,
        mappings: [(output: Int, source: Int)],
        fillColor: (Int, Int, Int),
        tileOriginX: Int,
        tileOriginY: Int,
        tileSize: Int,
        output: inout [UInt8]
    ) {
        let intersectionMinX = max(Int(floor(placement.x)), tileOriginX)
        let intersectionMinY = max(Int(floor(placement.y)), tileOriginY)
        let intersectionMaxX = min(
            Int(ceil(placement.x + placement.width)),
            tileOriginX + tileSize
        )
        let intersectionMaxY = min(
            Int(ceil(placement.y + placement.height)),
            tileOriginY + tileSize
        )
        guard intersectionMinX < intersectionMaxX,
              intersectionMinY < intersectionMaxY else { return }

        for globalY in intersectionMinY..<intersectionMaxY {
            let sourceY = Int(floor(
                placement.sourceY + Double(globalY) + 0.5 - placement.y
            ))
            guard sourceY >= 0, sourceY < decoded.height else { continue }
            let destinationY = globalY - tileOriginY
            for globalX in intersectionMinX..<intersectionMaxX {
                let sourceX = Int(floor(
                    placement.sourceX + Double(globalX) + 0.5 - placement.x
                ))
                guard sourceX >= 0, sourceX < decoded.width else { continue }
                let sourceOffset = (sourceY * decoded.width + sourceX) * 4
                let red = Int(decoded.pixels[sourceOffset])
                let green = Int(decoded.pixels[sourceOffset + 1])
                let blue = Int(decoded.pixels[sourceOffset + 2])
                let isFill = abs(red - fillColor.0) <= 3
                    && abs(green - fillColor.1) <= 3
                    && abs(blue - fillColor.2) <= 3
                guard !isFill else { continue }

                let destinationX = globalX - tileOriginX
                let destinationOffset = (destinationY * tileSize + destinationX) * 4
                for mapping in mappings where (0..<4).contains(mapping.output)
                    && (0..<3).contains(mapping.source) {
                    output[destinationOffset + mapping.output] =
                        decoded.pixels[sourceOffset + mapping.source]
                }
            }
        }
    }

    private static func tileEntries(
        indexData: Data,
        hierarchicalTableBase: Int,
        recordIndex: Int
    ) throws -> [MRXSTileEntry] {
        let listHead = try MRXSNativeReader.readInt32(
            indexData,
            at: hierarchicalTableBase + recordIndex * 4
        )
        guard listHead > 0,
              try MRXSNativeReader.readInt32(indexData, at: listHead) == 0 else {
            return []
        }
        var page = try MRXSNativeReader.readInt32(indexData, at: listHead + 4)
        var entries: [MRXSTileEntry] = []
        var visited: Set<Int> = []
        while page > 0, visited.insert(page).inserted {
            let count = try MRXSNativeReader.readInt32(indexData, at: page)
            let next = try MRXSNativeReader.readInt32(indexData, at: page + 4)
            guard count >= 0, count < 1_000_000 else {
                throw SlideTileError.invalidData("MRXS Index.dat 页面长度异常")
            }
            for index in 0..<count {
                let offset = page + 8 + index * 16
                entries.append(MRXSTileEntry(
                    imageIndex: try MRXSNativeReader.readInt32(indexData, at: offset),
                    offset: try MRXSNativeReader.readInt32(indexData, at: offset + 4),
                    size: try MRXSNativeReader.readInt32(indexData, at: offset + 8),
                    fileNumber: try MRXSNativeReader.readInt32(indexData, at: offset + 12)
                ))
            }
            page = next
        }
        return entries
    }

    private static func readStagePositions(
        metadata: MRXSMetadata,
        indexData: Data,
        slideDirectory: URL,
        nonhierarchicalRoot: Int
    ) throws -> [MRXSStagePosition] {
        let positionsAcross = metadata.tileCountX / metadata.imageDivisions
        let positionsDown = metadata.tileCountY / metadata.imageDivisions
        let positionCount = positionsAcross * positionsDown
        let expectedSize = positionCount * 9
        let levelZeroImageConcat = 1 << max(metadata.concatExponents.first ?? 0, 0)

        guard let recordIndex = metadata.positionRecordIndex else {
            let advanceX = metadata.tileWidths[0] * metadata.imageDivisions
                - Int(metadata.overlapX[0].rounded())
            let advanceY = metadata.tileHeights[0] * metadata.imageDivisions
                - Int(metadata.overlapY[0].rounded())
            return (0..<positionCount).map {
                MRXSStagePosition(
                    x: ($0 % positionsAcross) * advanceX,
                    y: ($0 / positionsAcross) * advanceY
                )
            }
        }

        let tableBase = try MRXSNativeReader.readInt32(indexData, at: nonhierarchicalRoot)
        let listHead = try MRXSNativeReader.readInt32(
            indexData,
            at: tableBase + recordIndex * 4
        )
        guard listHead > 0,
              try MRXSNativeReader.readInt32(indexData, at: listHead) == 0 else {
            throw SlideTileError.invalidData("MRXS 位置表入口无效")
        }
        let page = try MRXSNativeReader.readInt32(indexData, at: listHead + 4)
        guard page > 0,
              try MRXSNativeReader.readInt32(indexData, at: page) > 0,
              try MRXSNativeReader.readInt32(indexData, at: page + 8) == 0,
              try MRXSNativeReader.readInt32(indexData, at: page + 12) == 0 else {
            throw SlideTileError.invalidData("MRXS 位置表页面无效")
        }
        let dataOffset = try MRXSNativeReader.readInt32(indexData, at: page + 16)
        let dataSize = try MRXSNativeReader.readInt32(indexData, at: page + 20)
        let fileNumber = try MRXSNativeReader.readInt32(indexData, at: page + 24)
        guard fileNumber >= 0,
              fileNumber < metadata.dataFiles.count,
              dataOffset >= 0,
              dataSize > 0 else {
            throw SlideTileError.invalidData("MRXS 位置表数据指针无效")
        }

        let fileData = try Data(
            contentsOf: slideDirectory.appendingPathComponent(metadata.dataFiles[fileNumber]),
            options: .mappedIfSafe
        )
        guard dataOffset + dataSize <= fileData.count else {
            throw SlideTileError.invalidData("MRXS 位置表数据越界")
        }
        let stored = fileData.subdata(in: dataOffset..<(dataOffset + dataSize))
        let positionData: Data
        if metadata.positionRecordIsCompressed {
            positionData = try decompressZlib(stored, expectedSize: expectedSize)
        } else {
            guard stored.count == expectedSize else {
                throw SlideTileError.invalidData("MRXS 位置表长度不匹配")
            }
            positionData = stored
        }

        var positions: [MRXSStagePosition] = []
        positions.reserveCapacity(positionCount)
        for index in 0..<positionCount {
            let offset = index * 9
            let flag = positionData[offset]
            guard flag == 0 || flag == 1 else {
                throw SlideTileError.invalidData("MRXS 位置表标志位异常")
            }
            let x = try MRXSNativeReader.readInt32(positionData, at: offset + 1)
            let y = try MRXSNativeReader.readInt32(positionData, at: offset + 5)
            positions.append(MRXSStagePosition(
                x: x * levelZeroImageConcat,
                y: y * levelZeroImageConcat
            ))
        }
        return positions
    }

    private static func decompressZlib(_ data: Data, expectedSize: Int) throws -> Data {
        var output = [UInt8](repeating: 0, count: expectedSize)
        var decodedSize = uLongf(expectedSize)
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                uncompress(
                    destination.bindMemory(to: Bytef.self).baseAddress!,
                    &decodedSize,
                    source.bindMemory(to: Bytef.self).baseAddress!,
                    uLong(data.count)
                )
            }
        }
        guard status == Z_OK, decodedSize == expectedSize else {
            throw SlideTileError.invalidData("MRXS 压缩位置表解压失败")
        }
        return Data(output)
    }

    private static func spatialKey(column: Int, row: Int) -> Int64 {
        (Int64(row) << 32) | Int64(UInt32(column))
    }
}
