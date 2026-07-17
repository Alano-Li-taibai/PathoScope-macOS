import Foundation

private final class OpenSlideTileWorker: @unchecked Sendable {
    private static let responseMagic: UInt32 = 0x5053544c

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let lock = NSLock()

    init(helperURL: URL, slideURL: URL) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = [slideURL.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        guard process.isRunning else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "helper 未启动"
            throw SlideTileError.helperFailed(message)
        }
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading
    }

    deinit {
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func read(level: Int, x: Int64, y: Int64, width: Int, height: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else {
            let message = String(
                data: errorOutput.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "helper 已退出"
            throw SlideTileError.helperFailed(message)
        }
        let request = "\(level) \(x) \(y) \(width) \(height)\n"
        try input.write(contentsOf: Data(request.utf8))
        let header = try readExactly(20)
        let magic = Self.readUInt32(header, at: 0)
        let status = Self.readUInt32(header, at: 4)
        let responseWidth = Self.readUInt32(header, at: 8)
        let responseHeight = Self.readUInt32(header, at: 12)
        let payloadSize = Self.readUInt32(header, at: 16)
        guard magic == Self.responseMagic else {
            throw SlideTileError.helperFailed("helper 响应头损坏")
        }
        let payload = try readExactly(Int(payloadSize))
        guard status == 0 else {
            throw SlideTileError.helperFailed(
                String(data: payload, encoding: .utf8) ?? "OpenSlide 未知错误"
            )
        }
        guard responseWidth == width,
              responseHeight == height,
              payload.count == width * height * 4 else {
            throw SlideTileError.helperFailed("helper 返回尺寸不匹配")
        }
        return payload
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try output.read(upToCount: count - result.count),
                  !chunk.isEmpty else {
                throw SlideTileError.helperFailed("helper 提前关闭输出")
            }
            result.append(chunk)
        }
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

public actor OpenSlideTileSource: SlideTileSource {
    public nonisolated let descriptor: SlideTileSourceDescriptor

    private let boundsX: Int
    private let boundsY: Int
    private let sourceLevels: [(primary: Int, secondary: Int?)]
    private let workers: [OpenSlideTileWorker]
    private let tileSize: Int

    public init(
        slide: ImportedSlide,
        helperURL: URL,
        tileSize: Int = 512,
        workerCount: Int = 3
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SlideTileError.helperUnavailable(helperURL.path)
        }
        let properties = try Self.showProperties(
            helperURL: helperURL,
            for: slide.sourceURL
        )
        let metadata = try SlidePyramidMetadata.parse(properties: properties)
        guard let base = metadata.levels.first else {
            throw SlideTileError.invalidData("OpenSlide 未返回金字塔")
        }
        let hasBounds = metadata.boundsX != nil
            && metadata.boundsY != nil
            && metadata.boundsWidth != nil
            && metadata.boundsHeight != nil
        let boundsX = hasBounds ? metadata.boundsX! : 0
        let boundsY = hasBounds ? metadata.boundsY! : 0
        let boundedWidth = hasBounds ? metadata.boundsWidth! : base.width
        let boundedHeight = hasBounds ? metadata.boundsHeight! : base.height
        let safeTileSize = tileSize == 256 ? 256 : 512

        var sourceLevels: [(primary: Int, secondary: Int?)] = []
        var levelDescriptors: [SlideTileLevel] = []
        var sourceIndex = 0
        while sourceIndex < metadata.levels.count {
            let sourceLevel = metadata.levels[sourceIndex]
            let secondary = metadata.pairedLevel(after: sourceLevel.index)
            let displayIndex = sourceLevels.count
            sourceLevels.append((sourceLevel.index, secondary))
            levelDescriptors.append(SlideTileLevel(
                index: displayIndex,
                width: max(1, Int(ceil(Double(boundedWidth) / sourceLevel.downsample))),
                height: max(1, Int(ceil(Double(boundedHeight) / sourceLevel.downsample))),
                downsample: sourceLevel.downsample
            ))
            sourceIndex += secondary == nil ? 1 : 2
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: slide.sourceURL.path)
        let sourceSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprintSeed = "\(slide.sourceURL.path)|\(sourceSize)|\(Int64(modified))|openslide-v4"
        let fingerprint = String(format: "%016llx", Self.fnv1a64(fingerprintSeed.utf8))
        let supportsFourChannels = slide.format == .svs
            && sourceLevels.contains(where: { $0.secondary != nil })
        let channels: [SlideTileChannelDescriptor]
        if supportsFourChannels {
            channels = [
                SlideTileChannelDescriptor(id: "svs-dapi", name: "DAPI", red: 0, green: 0, blue: 1),
                SlideTileChannelDescriptor(id: "svs-if488", name: "IF488", red: 1, green: 0, blue: 0),
                SlideTileChannelDescriptor(id: "svs-if555", name: "IF555", red: 0, green: 1, blue: 0),
                SlideTileChannelDescriptor(id: "svs-if647", name: "IF647", red: 1, green: 1, blue: 0)
            ]
        } else {
            channels = []
        }
        let workers = try (0..<max(1, workerCount)).map { _ in
            try OpenSlideTileWorker(helperURL: helperURL, slideURL: slide.sourceURL)
        }

        self.boundsX = boundsX
        self.boundsY = boundsY
        self.sourceLevels = sourceLevels
        self.workers = workers
        self.tileSize = safeTileSize
        self.descriptor = SlideTileSourceDescriptor(
            fingerprint: fingerprint,
            tileSize: safeTileSize,
            levels: levelDescriptors,
            micronsPerPixelX: metadata.micronsPerPixelX,
            micronsPerPixelY: metadata.micronsPerPixelY,
            renderMode: supportsFourChannels ? .fourChannel : .rgb,
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
        let displayLevel = descriptor.levels[key.level]
        guard key.column * tileSize < displayLevel.width,
              key.row * tileSize < displayLevel.height else {
            throw SlideTileError.invalidKey
        }
        let sourceLevel = sourceLevels[key.level]
        let x = Int64(boundsX) + Int64(
            (Double(key.column * tileSize) * displayLevel.downsample).rounded(.down)
        )
        let y = Int64(boundsY) + Int64(
            (Double(key.row * tileSize) * displayLevel.downsample).rounded(.down)
        )
        let worker = workers[
            abs(key.column &* 31 &+ key.row &* 17 &+ key.level) % workers.count
        ]
        let requestSize = tileSize
        let primary = try await Task.detached(priority: .userInitiated) {
            try worker.read(
                level: sourceLevel.primary,
                x: x,
                y: y,
                width: requestSize,
                height: requestSize
            )
        }.value

        let bytes: Data
        if descriptor.renderMode == .fourChannel, let secondaryLevel = sourceLevel.secondary {
            try Task.checkCancellation()
            let secondary = try await Task.detached(priority: .userInitiated) {
                try worker.read(
                    level: secondaryLevel,
                    x: x,
                    y: y,
                    width: requestSize,
                    height: requestSize
                )
            }.value
            bytes = Self.packSVSChannels(primary: primary, secondary: secondary)
        } else {
            bytes = Self.convertBGRAtoRGBA(primary)
        }
        return SlideTileData(key: key, width: tileSize, height: tileSize, bytes: bytes)
    }

    private static func packSVSChannels(primary: Data, secondary: Data) -> Data {
        let primaryBytes = [UInt8](primary)
        let secondaryBytes = [UInt8](secondary)
        var output = [UInt8](repeating: 0, count: primaryBytes.count)
        for offset in stride(from: 0, to: primaryBytes.count, by: 4) {
            guard primaryBytes[offset + 3] > 0 else { continue }
            output[offset] = primaryBytes[offset]
            output[offset + 1] = primaryBytes[offset + 2]
            output[offset + 2] = primaryBytes[offset + 1]
            output[offset + 3] = secondaryBytes[offset + 2]
        }
        return Data(output)
    }

    private static func convertBGRAtoRGBA(_ input: Data) -> Data {
        let source = [UInt8](input)
        var output = source
        for offset in stride(from: 0, to: source.count, by: 4) {
            output[offset] = source[offset + 2]
            output[offset + 1] = source[offset + 1]
            output[offset + 2] = source[offset]
            output[offset + 3] = source[offset + 3]
        }
        return Data(output)
    }

    private static func showProperties(
        helperURL: URL,
        for slideURL: URL
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--properties", slideURL.path]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw SlideTileError.helperFailed(
                String(data: stderr, encoding: .utf8) ?? "属性读取失败"
            )
        }
        return String(data: stdout, encoding: .utf8) ?? ""
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
