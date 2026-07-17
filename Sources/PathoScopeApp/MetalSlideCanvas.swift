import Metal
import MetalKit
import PathoScopeCore
import SwiftUI

private struct MetalTileInstance {
    var rect: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var sliceAndPadding: SIMD4<UInt32>
}

private struct MetalChannelSetting {
    var color: SIMD4<Float>
    var curve: SIMD4<Float>
    var extra: SIMD4<Float>
}

@MainActor
struct MetalSlideCanvas: NSViewRepresentable {
    let session: TileRenderSession
    let centerX: Double
    let centerY: Double
    let zoom: Double
    let transientMagnification: CGFloat
    let transientPan: CGSize
    let viewportSize: CGSize
    let channelSettings: [ChannelDisplaySettings]

    func makeNSView(context: Context) -> MetalSlideNSView {
        MetalSlideNSView()
    }

    func updateNSView(_ nsView: MetalSlideNSView, context: Context) {
        nsView.update(
            session: session,
            centerX: centerX,
            centerY: centerY,
            zoom: zoom,
            transientMagnification: transientMagnification,
            transientPan: transientPan,
            viewportSize: viewportSize,
            channelSettings: channelSettings
        )
    }

    static func dismantleNSView(_ nsView: MetalSlideNSView, coordinator: ()) {
        nsView.stop()
    }
}

@MainActor
final class MetalSlideNSView: MTKView {
    private var tileRenderer: MetalTileRenderer!

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device is required")
        }
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        tileRenderer = try! MetalTileRenderer(view: self, device: device)
        delegate = tileRenderer
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        session: TileRenderSession,
        centerX: Double,
        centerY: Double,
        zoom: Double,
        transientMagnification: CGFloat,
        transientPan: CGSize,
        viewportSize: CGSize,
        channelSettings: [ChannelDisplaySettings]
    ) {
        tileRenderer.update(
            session: session,
            centerX: centerX,
            centerY: centerY,
            zoom: zoom,
            transientMagnification: transientMagnification,
            transientPan: transientPan,
            viewportSize: viewportSize,
            backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            channelSettings: channelSettings
        )
    }

    func stop() {
        tileRenderer.stop()
    }
}

@MainActor
private final class MetalTileAtlas {
    let texture: MTLTexture

    private struct Slot {
        let slice: Int
        var access: UInt64
    }

    private var slots: [SlideTileKey: Slot] = [:]
    private var keysBySlice: [Int: SlideTileKey] = [:]
    private var freeSlices: [Int]
    private var clock: UInt64 = 0

    init(device: MTLDevice, tileSize: Int, capacity: Int) {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = tileSize
        descriptor.height = tileSize
        descriptor.arrayLength = capacity
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Unable to create Metal tile atlas")
        }
        self.texture = texture
        self.freeSlices = Array((0..<capacity).reversed())
    }

    func clear() {
        slots.removeAll(keepingCapacity: true)
        keysBySlice.removeAll(keepingCapacity: true)
        freeSlices = Array((0..<texture.arrayLength).reversed())
        clock = 0
    }

    func slice(for key: SlideTileKey) -> Int? {
        guard var slot = slots[key] else { return nil }
        clock &+= 1
        slot.access = clock
        slots[key] = slot
        return slot.slice
    }

    func upload(_ tile: SlideTileData, protecting protectedKeys: Set<SlideTileKey>) {
        guard tile.width == texture.width,
              tile.height == texture.height,
              tile.bytes.count == texture.width * texture.height * 4 else { return }
        let slice: Int
        if let existing = slots[tile.key] {
            slice = existing.slice
        } else if let free = freeSlices.popLast() {
            slice = free
        } else {
            let candidates = slots.filter { !protectedKeys.contains($0.key) }
            let victim = (candidates.isEmpty ? slots : candidates)
                .min(by: { $0.value.access < $1.value.access })!
            slice = victim.value.slice
            slots.removeValue(forKey: victim.key)
            keysBySlice.removeValue(forKey: slice)
        }

        tile.bytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, tile.width, tile.height),
                mipmapLevel: 0,
                slice: slice,
                withBytes: baseAddress,
                bytesPerRow: tile.width * 4,
                bytesPerImage: tile.width * tile.height * 4
            )
        }
        clock &+= 1
        slots[tile.key] = Slot(slice: slice, access: clock)
        keysBySlice[slice] = tile.key
    }
}

@MainActor
private final class MetalTileRenderer: NSObject, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TileInstance {
        float4 rect;
        float4 uvRect;
        uint4 sliceAndPadding;
    };

    struct ChannelSetting {
        float4 color;
        float4 curve;
        float4 extra;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        uint slice [[flat]];
    };

    vertex VertexOut tileVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant TileInstance *instances [[buffer(0)]]
    ) {
        const float2 unitPositions[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };
        TileInstance instance = instances[instanceID];
        float2 unit = unitPositions[vertexID];
        VertexOut output;
        output.position = float4(
            mix(instance.rect.x, instance.rect.y, unit.x),
            mix(instance.rect.z, instance.rect.w, unit.y),
            0.0,
            1.0
        );
        output.uv = float2(
            mix(instance.uvRect.x, instance.uvRect.z, unit.x),
            mix(instance.uvRect.y, instance.uvRect.w, unit.y)
        );
        output.slice = instance.sliceAndPadding.x;
        return output;
    }

    fragment float4 tileFragment(
        VertexOut input [[stage_in]],
        texture2d_array<float> atlas [[texture(0)]],
        constant ChannelSetting *settings [[buffer(0)]],
        constant uint &mode [[buffer(1)]]
    ) {
        constexpr sampler tileSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear
        );
        float4 signal = atlas.sample(tileSampler, input.uv, input.slice);
        if (mode == 0) {
            return float4(signal.rgb, 1.0);
        }

        float3 result = float3(0.0);
        for (uint index = 0; index < 4; index++) {
            ChannelSetting setting = settings[index];
            if (setting.color.w <= 0.0) {
                continue;
            }
            float black = setting.curve.x;
            float white = max(setting.curve.y, black + 0.0001);
            float gamma = max(setting.curve.z, 0.05);
            float value = clamp((signal[index] - black) / (white - black), 0.0, 1.0);
            value = pow(value, 1.0 / gamma);
            value *= exp2(setting.curve.w * 4.0);
            value = clamp((value - 0.5) * setting.extra.x + 0.5, 0.0, 1.0);
            result += value * setting.color.rgb;
        }
        return float4(clamp(result, 0.0, 1.0), 1.0);
    }
    """

    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var atlas: MetalTileAtlas
    private var session: TileRenderSession?
    private var sessionID: UUID?
    private var descriptor: SlideTileSourceDescriptor?
    private var visibleRect = SlideViewportGeometry(x: 0, y: 0, width: 1, height: 1)
    private var viewportSize = CGSize(width: 1, height: 1)
    private var transientMagnification: CGFloat = 1
    private var transientPan: CGSize = .zero
    private var channelSettings: [ChannelDisplaySettings] = []
    private var parentKeys: [SlideTileKey] = []
    private var targetKeys: [SlideTileKey] = []
    private var protectedKeys: Set<SlideTileKey> = []
    private var inFlight: [SlideTileKey: Task<Void, Never>] = [:]

    init(view: MTKView, device: MTLDevice) throws {
        self.view = view
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw SlideTileError.invalidData("Metal command queue 创建失败")
        }
        self.commandQueue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "tileVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.atlas = MetalTileAtlas(device: device, tileSize: 512, capacity: 256)
        super.init()
    }

    func update(
        session: TileRenderSession,
        centerX: Double,
        centerY: Double,
        zoom: Double,
        transientMagnification: CGFloat,
        transientPan: CGSize,
        viewportSize: CGSize,
        backingScale: CGFloat,
        channelSettings: [ChannelDisplaySettings]
    ) {
        let descriptor = session.descriptor
        if sessionID != session.id {
            inFlight.values.forEach { $0.cancel() }
            inFlight.removeAll()
            if atlas.texture.width == descriptor.tileSize {
                atlas.clear()
            } else {
                atlas = MetalTileAtlas(
                    device: device,
                    tileSize: descriptor.tileSize,
                    capacity: descriptor.tileSize == 256 ? 768 : 256
                )
            }
            sessionID = session.id
        }
        self.session = session
        self.descriptor = descriptor
        self.viewportSize = CGSize(
            width: max(viewportSize.width, 1),
            height: max(viewportSize.height, 1)
        )
        self.transientMagnification = transientMagnification
        self.transientPan = transientPan
        self.channelSettings = channelSettings

        let aspect = Double(self.viewportSize.width / self.viewportSize.height)
        let baseVisibleRect = SlideViewportGeometry.visibleLevelZeroRect(
            descriptor: descriptor,
            centerX: centerX,
            centerY: centerY,
            zoom: zoom,
            aspectRatio: aspect
        )
        self.visibleRect = baseVisibleRect
        let requestVisibleRect = transformedVisibleRect(
            base: baseVisibleRect,
            descriptor: descriptor,
            magnification: transientMagnification,
            pan: transientPan,
            viewportSize: self.viewportSize
        )
        let targetLevelIndex = SlideViewportGeometry.bestLevel(
            descriptor: descriptor,
            visibleRect: requestVisibleRect,
            viewportPixelWidth: Double(self.viewportSize.width * backingScale),
            viewportPixelHeight: Double(self.viewportSize.height * backingScale)
        )
        guard let levelPosition = descriptor.levels.firstIndex(where: {
            $0.index == targetLevelIndex
        }) else { return }

        targetKeys = keys(
            descriptor: descriptor,
            level: descriptor.levels[levelPosition],
            visibleRect: requestVisibleRect,
            ring: 0
        )
        let targetPrefetch = keys(
            descriptor: descriptor,
            level: descriptor.levels[levelPosition],
            visibleRect: requestVisibleRect,
            ring: 1
        )
        if levelPosition + 1 < descriptor.levels.count {
            parentKeys = keys(
                descriptor: descriptor,
                level: descriptor.levels[levelPosition + 1],
                visibleRect: requestVisibleRect,
                ring: 0
            )
        } else {
            parentKeys = []
        }
        protectedKeys = Set(parentKeys + targetKeys)
        let targetVisible = Set(targetKeys)
        let prefetch = targetPrefetch.filter { !targetVisible.contains($0) }
        request(parentKeys, from: session, priority: .userInitiated)
        request(targetKeys, from: session, priority: .userInitiated)
        request(prefetch, from: session, priority: .utility)
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    private func transformedVisibleRect(
        base: SlideViewportGeometry,
        descriptor: SlideTileSourceDescriptor,
        magnification: CGFloat,
        pan: CGSize,
        viewportSize: CGSize
    ) -> SlideViewportGeometry {
        let scale = max(Double(magnification), 0.2)
        let width = min(Double(descriptor.levelZeroWidth), base.width / scale)
        let height = min(Double(descriptor.levelZeroHeight), base.height / scale)
        let centerX = base.x + base.width / 2
            - Double(pan.width / max(viewportSize.width, 1)) * base.width / scale
        let centerY = base.y + base.height / 2
            - Double(pan.height / max(viewportSize.height, 1)) * base.height / scale
        let x = min(
            max(centerX - width / 2, 0),
            max(Double(descriptor.levelZeroWidth) - width, 0)
        )
        let y = min(
            max(centerY - height / 2, 0),
            max(Double(descriptor.levelZeroHeight) - height, 0)
        )
        return SlideViewportGeometry(x: x, y: y, width: width, height: height)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let descriptor,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
              ) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        let settings = gpuSettings(descriptor: descriptor)
        settings.withUnsafeBufferPointer { pointer in
            encoder.setFragmentBytes(
                pointer.baseAddress!,
                length: pointer.count * MemoryLayout<MetalChannelSetting>.stride,
                index: 0
            )
        }
        var mode = UInt32(descriptor.renderMode.rawValue)
        encoder.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 1)
        encode(parentKeys, descriptor: descriptor, with: encoder)
        encode(targetKeys, descriptor: descriptor, with: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func stop() {
        let previousSession = session
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        session = nil
        sessionID = nil
        parentKeys = []
        targetKeys = []
        protectedKeys = []
        if let previousSession {
            Task { await previousSession.cancelPending() }
        }
    }

    private func request(
        _ keys: [SlideTileKey],
        from session: TileRenderSession,
        priority: TaskPriority
    ) {
        for key in keys {
            if atlas.slice(for: key) != nil || inFlight[key] != nil { continue }
            let expectedSessionID = session.id
            inFlight[key] = Task(priority: priority) { [weak self] in
                guard let self else { return }
                do {
                    let tile = try await session.tile(for: key)
                    guard !Task.isCancelled, self.sessionID == expectedSessionID else { return }
                    self.atlas.upload(tile, protecting: self.protectedKeys)
                    self.view?.setNeedsDisplay(self.view?.bounds ?? .zero)
                } catch {
                    // Failed prefetch tiles are retried on the next viewport update.
                }
                self.inFlight.removeValue(forKey: key)
            }
        }
    }

    private func keys(
        descriptor: SlideTileSourceDescriptor,
        level: SlideTileLevel,
        visibleRect: SlideViewportGeometry,
        ring: Int
    ) -> [SlideTileKey] {
        let tileSize = Double(descriptor.tileSize)
        let minimumColumn = max(
            0,
            Int(floor(visibleRect.x / level.downsample / tileSize)) - ring
        )
        let maximumColumn = min(
            max(0, Int(ceil(Double(level.width) / tileSize)) - 1),
            Int(floor(
                (visibleRect.x + visibleRect.width - 0.000_001)
                    / level.downsample
                    / tileSize
            )) + ring
        )
        let minimumRow = max(
            0,
            Int(floor(visibleRect.y / level.downsample / tileSize)) - ring
        )
        let maximumRow = min(
            max(0, Int(ceil(Double(level.height) / tileSize)) - 1),
            Int(floor(
                (visibleRect.y + visibleRect.height - 0.000_001)
                    / level.downsample
                    / tileSize
            )) + ring
        )
        guard minimumColumn <= maximumColumn, minimumRow <= maximumRow else { return [] }
        let centerColumn = (
            visibleRect.x + visibleRect.width / 2
        ) / level.downsample / tileSize
        let centerRow = (
            visibleRect.y + visibleRect.height / 2
        ) / level.downsample / tileSize
        var result: [SlideTileKey] = []
        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                result.append(SlideTileKey(
                    fingerprint: descriptor.fingerprint,
                    level: level.index,
                    column: column,
                    row: row
                ))
            }
        }
        return result.sorted {
            let left = pow(Double($0.column) - centerColumn, 2)
                + pow(Double($0.row) - centerRow, 2)
            let right = pow(Double($1.column) - centerColumn, 2)
                + pow(Double($1.row) - centerRow, 2)
            return left < right
        }
    }

    private func encode(
        _ keys: [SlideTileKey],
        descriptor: SlideTileSourceDescriptor,
        with encoder: MTLRenderCommandEncoder
    ) {
        let instances = keys.compactMap { instance(for: $0, descriptor: descriptor) }
        guard !instances.isEmpty else { return }
        instances.withUnsafeBufferPointer { pointer in
            encoder.setVertexBytes(
                pointer.baseAddress!,
                length: pointer.count * MemoryLayout<MetalTileInstance>.stride,
                index: 0
            )
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: instances.count
            )
        }
    }

    private func instance(
        for key: SlideTileKey,
        descriptor: SlideTileSourceDescriptor
    ) -> MetalTileInstance? {
        guard let slice = atlas.slice(for: key),
              let level = descriptor.levels.first(where: { $0.index == key.level }) else {
            return nil
        }
        let worldX = Double(key.column * descriptor.tileSize) * level.downsample
        let worldY = Double(key.row * descriptor.tileSize) * level.downsample
        let worldWidth = min(
            Double(descriptor.tileSize),
            Double(level.width - key.column * descriptor.tileSize)
        ) * level.downsample
        let worldHeight = min(
            Double(descriptor.tileSize),
            Double(level.height - key.row * descriptor.tileSize)
        ) * level.downsample
        let magnification = Double(transientMagnification)
        let panX = 2 * Double(transientPan.width / viewportSize.width)
        let panY = -2 * Double(transientPan.height / viewportSize.height)
        let left = (
            ((worldX - visibleRect.x) / visibleRect.width) * 2 - 1
        ) * magnification + panX
        let right = (
            ((worldX + worldWidth - visibleRect.x) / visibleRect.width) * 2 - 1
        ) * magnification + panX
        let top = (
            1 - ((worldY - visibleRect.y) / visibleRect.height) * 2
        ) * magnification + panY
        let bottom = (
            1 - ((worldY + worldHeight - visibleRect.y) / visibleRect.height) * 2
        ) * magnification + panY
        let uMax = Float(worldWidth / level.downsample / Double(descriptor.tileSize))
        let vMax = Float(worldHeight / level.downsample / Double(descriptor.tileSize))
        return MetalTileInstance(
            rect: SIMD4(Float(left), Float(right), Float(top), Float(bottom)),
            uvRect: SIMD4(0, 0, uMax, vMax),
            sliceAndPadding: SIMD4(UInt32(slice), 0, 0, 0)
        )
    }

    private func gpuSettings(
        descriptor: SlideTileSourceDescriptor
    ) -> [MetalChannelSetting] {
        let settingsByID = Dictionary(uniqueKeysWithValues: channelSettings.map {
            ($0.id, $0)
        })
        return (0..<4).map { index in
            guard index < descriptor.channels.count else {
                return MetalChannelSetting(
                    color: .zero,
                    curve: SIMD4(0, 1, 1, 0),
                    extra: SIMD4(1, 0, 0, 0)
                )
            }
            let channel = descriptor.channels[index]
            let setting = settingsByID[channel.id]
            return MetalChannelSetting(
                color: SIMD4(
                    Float(setting?.red ?? channel.red),
                    Float(setting?.green ?? channel.green),
                    Float(setting?.blue ?? channel.blue),
                    setting?.isVisible == false ? 0 : 1
                ),
                curve: SIMD4(
                    Float(setting?.black ?? channel.defaultBlack),
                    Float(setting?.white ?? channel.defaultWhite),
                    Float(setting?.gamma ?? channel.defaultGamma),
                    Float(setting?.brightness ?? 0)
                ),
                extra: SIMD4(Float(setting?.contrast ?? 1), 0, 0, 0)
            )
        }
    }
}
