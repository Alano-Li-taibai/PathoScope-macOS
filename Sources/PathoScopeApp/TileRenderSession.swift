import Foundation
import PathoScopeCore

private actor TileDiskLRU {
    private static let magic = Data([0x50, 0x53, 0x54, 0x34])

    private let directory: URL
    private let maximumBytes: Int64
    private let fileManager = FileManager.default
    private var writesSinceSweep = 0

    init(directory: URL, maximumBytes: Int64) throws {
        self.directory = directory
        self.maximumBytes = maximumBytes
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.sweep(
            directory: directory,
            maximumBytes: maximumBytes,
            fileManager: fileManager
        )
    }

    func value(for key: SlideTileKey) -> SlideTileData? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 16,
              data.prefix(4) == Self.magic else { return nil }
        let width = Int(readUInt32(data, at: 4))
        let height = Int(readUInt32(data, at: 8))
        let byteCount = Int(readUInt32(data, at: 12))
        guard width > 0,
              height > 0,
              byteCount == width * height * 4,
              data.count == 16 + byteCount else { return nil }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return SlideTileData(
            key: key,
            width: width,
            height: height,
            bytes: data.subdata(in: 16..<data.count)
        )
    }

    func insert(_ tile: SlideTileData) {
        var data = Data()
        data.reserveCapacity(16 + tile.bytes.count)
        data.append(Self.magic)
        appendUInt32(UInt32(tile.width), to: &data)
        appendUInt32(UInt32(tile.height), to: &data)
        appendUInt32(UInt32(tile.bytes.count), to: &data)
        data.append(tile.bytes)
        try? data.write(to: fileURL(for: tile.key), options: .atomic)
        writesSinceSweep += 1
        if writesSinceSweep >= 32 {
            writesSinceSweep = 0
            try? sweep()
        }
    }

    private func fileURL(for key: SlideTileKey) -> URL {
        let hash = String(format: "%016llx", Self.fnv1a64(key.cacheIdentifier.utf8))
        return directory.appendingPathComponent("\(hash).tile")
    }

    private func sweep() throws {
        try Self.sweep(
            directory: directory,
            maximumBytes: maximumBytes,
            fileManager: fileManager
        )
    }

    private static func sweep(
        directory: URL,
        maximumBytes: Int64,
        fileManager: FileManager
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard url.pathExtension == "tile",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (
                url,
                Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast
            )
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maximumBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? fileManager.removeItem(at: file.url)
            total -= file.size
            if total <= maximumBytes { break }
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

actor TileRenderSession {
    nonisolated let id = UUID()
    nonisolated let descriptor: SlideTileSourceDescriptor

    private struct MemoryEntry {
        let tile: SlideTileData
        var access: UInt64
    }

    private let source: any SlideTileSource
    private let diskCache: TileDiskLRU
    private let maximumMemoryBytes: Int
    private var memory: [SlideTileKey: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var clock: UInt64 = 0
    private var inFlight: [SlideTileKey: Task<SlideTileData, Error>] = [:]

    init(
        source: any SlideTileSource,
        cacheDirectory: URL,
        maximumMemoryBytes: Int = 512 * 1024 * 1024,
        maximumDiskBytes: Int64 = 4 * 1024 * 1024 * 1024
    ) throws {
        self.source = source
        self.descriptor = source.descriptor
        self.maximumMemoryBytes = maximumMemoryBytes
        self.diskCache = try TileDiskLRU(
            directory: cacheDirectory,
            maximumBytes: maximumDiskBytes
        )
    }

    func tile(for key: SlideTileKey) async throws -> SlideTileData {
        try Task.checkCancellation()
        clock &+= 1
        if var cached = memory[key] {
            cached.access = clock
            memory[key] = cached
            return cached.tile
        }
        if let disk = await diskCache.value(for: key) {
            insertIntoMemory(disk)
            return disk
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let source = source
        let task = Task<SlideTileData, Error> {
            try await source.tile(for: key)
        }
        inFlight[key] = task
        do {
            let tile = try await task.value
            try Task.checkCancellation()
            inFlight.removeValue(forKey: key)
            insertIntoMemory(tile)
            await diskCache.insert(tile)
            return tile
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }

    func cancelPending() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    /// Reads an exact level-zero rectangle from native tiles without applying display LUTs.
    func rawLevelZeroRegion(x: Int, y: Int, width: Int, height: Int) async throws -> Data {
        guard width > 0,
              height > 0,
              x >= 0,
              y >= 0,
              x + width <= descriptor.levelZeroWidth,
              y + height <= descriptor.levelZeroHeight else {
            throw SlideTileError.invalidData("ROI 超出切片边界")
        }
        let tileSize = descriptor.tileSize
        let minimumColumn = x / tileSize
        let maximumColumn = (x + width - 1) / tileSize
        let minimumRow = y / tileSize
        let maximumRow = (y + height - 1) / tileSize
        var output = [UInt8](repeating: 0, count: width * height * 4)

        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                try Task.checkCancellation()
                let key = SlideTileKey(
                    fingerprint: descriptor.fingerprint,
                    level: 0,
                    column: column,
                    row: row
                )
                let sourceTile = try await tile(for: key)
                let tileOriginX = column * tileSize
                let tileOriginY = row * tileSize
                let copyX0 = max(x, tileOriginX)
                let copyY0 = max(y, tileOriginY)
                let copyX1 = min(x + width, tileOriginX + sourceTile.width)
                let copyY1 = min(y + height, tileOriginY + sourceTile.height)
                guard copyX0 < copyX1, copyY0 < copyY1 else { continue }
                sourceTile.bytes.withUnsafeBytes { raw in
                    let source = raw.bindMemory(to: UInt8.self)
                    for worldY in copyY0..<copyY1 {
                        let sourceOffset = (
                            (worldY - tileOriginY) * sourceTile.width
                                + (copyX0 - tileOriginX)
                        ) * 4
                        let destinationOffset = (
                            (worldY - y) * width + (copyX0 - x)
                        ) * 4
                        let byteCount = (copyX1 - copyX0) * 4
                        for offset in 0..<byteCount {
                            output[destinationOffset + offset] = source[sourceOffset + offset]
                        }
                    }
                }
            }
        }
        return Data(output)
    }

    private func insertIntoMemory(_ tile: SlideTileData) {
        clock &+= 1
        if let existing = memory[tile.key] {
            memoryBytes -= existing.tile.memoryCost
        }
        memory[tile.key] = MemoryEntry(tile: tile, access: clock)
        memoryBytes += tile.memoryCost
        while memoryBytes > maximumMemoryBytes,
              let oldest = memory.min(by: { $0.value.access < $1.value.access }) {
            memoryBytes -= oldest.value.tile.memoryCost
            memory.removeValue(forKey: oldest.key)
        }
    }
}
