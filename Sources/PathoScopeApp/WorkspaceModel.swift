import AppKit
import Foundation
import PathoScopeCore

@MainActor
final class WorkspaceModel: ObservableObject {
    enum AnalysisSlot { case a, b }

    @Published private(set) var slides: [ImportedSlide] = []
    @Published var selectedSlideID: ImportedSlide.ID?
    @Published var showImporter = false
    @Published var importMessages: [String] = []
    @Published private(set) var tileSession: TileRenderSession?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var previewError: String?
    @Published private(set) var previewRevision = 0
    @Published private(set) var viewportZoom: Double = 1
    @Published private(set) var viewportCenterX: Double = 0.5
    @Published private(set) var viewportCenterY: Double = 0.5
    @Published private(set) var viewportAspectRatio: Double?
    @Published private(set) var viewportSize = CGSize(width: 1, height: 1)
    @Published private(set) var channelSettings: [ChannelDisplaySettings] = []
    @Published var roiSideMicrons: Double = 100
    @Published var isPlacingSquareROI = false
    @Published private(set) var rois: [SquareROIRecord] = []
    @Published var selectedROIID: UUID?
    @Published var roiCopyTargetSlideID: UUID?
    @Published var analysisSlideAID: UUID?
    @Published var analysisSlideBID: UUID?
    @Published var analysisROIAID: UUID?
    @Published var analysisROIBID: UUID?
    @Published var analysisChannelAID: String?
    @Published var analysisChannelBID: String?
    @Published private(set) var analysisResults: [ROIAnalysisResult] = []
    @Published private(set) var isAnalyzing = false

    private let importer = SlideImportService()
    private var rendererTask: Task<Void, Never>?
    private var rendererWorkerTask: Task<TileRenderSession, Error>?
    private var sessionsBySlideID: [UUID: TileRenderSession] = [:]
    private var channelAliasesBySlideID: [UUID: [String: String]] = [:]

    var selectedSlide: ImportedSlide? {
        slides.first(where: { $0.id == selectedSlideID })
    }

    var tileDescriptor: SlideTileSourceDescriptor? {
        tileSession?.descriptor
    }

    var visibleViewportRect: SlideViewportGeometry? {
        guard let descriptor = tileDescriptor else { return nil }
        return SlideViewportGeometry.visibleLevelZeroRect(
            descriptor: descriptor,
            centerX: viewportCenterX,
            centerY: viewportCenterY,
            zoom: viewportZoom,
            aspectRatio: viewportAspectRatio ?? descriptorAspectRatio(descriptor)
        )
    }

    var levelZeroMicronsPerPixel: Double? {
        tileDescriptor?.micronsPerPixelX
    }

    func importURLs(_ urls: [URL]) {
        importMessages = []
        var lastSelectedID: ImportedSlide.ID?
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let inspected = try importer.inspect(url)
                if let existing = slides.first(where: { $0.sourceURL == inspected.sourceURL }) {
                    lastSelectedID = existing.id
                } else {
                    slides.append(inspected)
                    lastSelectedID = inspected.id
                    if analysisSlideAID == nil {
                        analysisSlideAID = inspected.id
                    } else if analysisSlideBID == nil {
                        analysisSlideBID = inspected.id
                    }
                }
            } catch {
                importMessages.append(error.localizedDescription)
            }
        }
        if let lastSelectedID {
            selectSlide(lastSelectedID)
        }
    }

    func selectSlide(_ id: ImportedSlide.ID?) {
        selectedSlideID = id
        viewportZoom = 1
        viewportCenterX = 0.5
        viewportCenterY = 0.5
        channelSettings = []
        selectedROIID = rois.first(where: { $0.slideID == id })?.id
        roiCopyTargetSlideID = id
        loadSelectedRenderer()
    }

    func reloadPreview() {
        loadSelectedRenderer()
    }

    func zoom(by factor: Double) {
        let newZoom = min(max(viewportZoom * factor, 1), 128)
        guard abs(newZoom - viewportZoom) > 0.001 else { return }
        viewportZoom = newZoom
        clampViewportCenter()
    }

    func resetViewport() {
        viewportZoom = 1
        viewportCenterX = 0.5
        viewportCenterY = 0.5
        clampViewportCenter()
    }

    func pan(viewportFractionDX: Double, viewportFractionDY: Double) {
        guard let descriptor = tileDescriptor,
              let visible = visibleViewportRect else { return }
        viewportCenterX += viewportFractionDX
            * visible.width
            / max(Double(descriptor.levelZeroWidth), 1)
        viewportCenterY += viewportFractionDY
            * visible.height
            / max(Double(descriptor.levelZeroHeight), 1)
        clampViewportCenter()
    }

    func updateViewerSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ratio = Double(size.width / size.height)
        guard ratio.isFinite, ratio > 0 else { return }
        viewportSize = size
        viewportAspectRatio = ratio
        clampViewportCenter()
    }

    var hasExactSVSChannels: Bool {
        tileDescriptor?.channels.contains(where: { $0.id == "svs-if647" }) == true
    }

    var hasExactMRXSChannels: Bool {
        selectedSlide?.format == .mrxs && (tileDescriptor?.channels.count ?? 0) >= 4
    }

    var channelModeDescription: String {
        if hasExactMRXSChannels { return "MRXS 原始滤光层 · Metal" }
        if hasExactSVSChannels { return "SVS 独立通道 · Metal" }
        return "原始 RGB · Metal"
    }

    var effectiveMicronsPerPixel: Double? {
        guard let descriptor = tileDescriptor,
              let mpp = descriptor.micronsPerPixelX,
              let visible = visibleViewportRect else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let levelIndex = SlideViewportGeometry.bestLevel(
            descriptor: descriptor,
            visibleRect: visible,
            viewportPixelWidth: Double(max(viewportSize.width * scale, 1)),
            viewportPixelHeight: Double(max(viewportSize.height * scale, 1))
        )
        let downsample = descriptor.levels.first(where: { $0.index == levelIndex })?.downsample ?? 1
        return mpp * downsample
    }

    private func loadSelectedRenderer() {
        rendererTask?.cancel()
        rendererWorkerTask?.cancel()
        tileSession = nil
        channelSettings = []
        previewError = nil
        guard let slide = selectedSlide else {
            isLoadingPreview = false
            return
        }
        if let cached = sessionsBySlideID[slide.id] {
            tileSession = cached
            configureChannels(descriptor: cached.descriptor)
            previewRevision += 1
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true

        let selectedID = slide.id
        let worker = Task.detached(priority: .userInitiated) {
            try Self.makeSession(for: slide)
        }
        rendererWorkerTask = worker
        rendererTask = Task {
            do {
                let session = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, selectedSlideID == selectedID else { return }
                sessionsBySlideID[selectedID] = session
                tileSession = session
                configureChannels(descriptor: session.descriptor)
                initializeAliases(for: selectedID, descriptor: session.descriptor)
                initializeAnalysisDefaults(for: selectedID, descriptor: session.descriptor)
                previewRevision += 1
                isLoadingPreview = false
            } catch is CancellationError {
                if selectedSlideID == selectedID {
                    isLoadingPreview = false
                }
            } catch {
                guard selectedSlideID == selectedID else { return }
                previewError = error.localizedDescription
                isLoadingPreview = false
            }
        }
    }

    private func clampViewportCenter() {
        guard let descriptor = tileDescriptor else {
            viewportCenterX = min(max(viewportCenterX, 0), 1)
            viewportCenterY = min(max(viewportCenterY, 0), 1)
            return
        }
        let reference = SlideViewportGeometry.visibleLevelZeroRect(
            descriptor: descriptor,
            centerX: 0.5,
            centerY: 0.5,
            zoom: viewportZoom,
            aspectRatio: viewportAspectRatio ?? descriptorAspectRatio(descriptor)
        )
        let halfX = min(
            0.5,
            reference.width / max(Double(descriptor.levelZeroWidth) * 2, 1)
        )
        let halfY = min(
            0.5,
            reference.height / max(Double(descriptor.levelZeroHeight) * 2, 1)
        )
        viewportCenterX = min(max(viewportCenterX, halfX), 1 - halfX)
        viewportCenterY = min(max(viewportCenterY, halfY), 1 - halfY)
    }

    private func descriptorAspectRatio(_ descriptor: SlideTileSourceDescriptor) -> Double {
        Double(max(descriptor.levelZeroWidth, 1)) / Double(max(descriptor.levelZeroHeight, 1))
    }

    private func configureChannels(descriptor: SlideTileSourceDescriptor) {
        channelSettings = descriptor.channels.map { channel in
            ChannelDisplaySettings(
                id: channel.id,
                name: channel.name,
                red: channel.red,
                green: channel.green,
                blue: channel.blue,
                brightness: 0,
                contrast: 1,
                black: channel.defaultBlack,
                white: channel.defaultWhite,
                gamma: channel.defaultGamma
            )
        }
    }

    nonisolated private static func openSlideHelperURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment["PATHOSCOPE_OPENSLIDE_TILE_HELPER"]
            .map(URL.init(fileURLWithPath:))
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("openslide-tile-helper")
        let candidates = [
            environment,
            bundled,
            URL(fileURLWithPath: "/private/tmp/openslide-tile-helper")
        ].compactMap { $0 }
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    nonisolated private static func makeSession(for slide: ImportedSlide) throws -> TileRenderSession {
        let cacheDirectory = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("tile-cache", isDirectory: true)
        let source: any SlideTileSource
        if slide.format == .mrxs {
            source = try MRXSTileSource(slideURL: slide.sourceURL, tileSize: 512)
        } else {
            guard let helperURL = openSlideHelperURL() else {
                throw SlideTileError.helperUnavailable("openslide-tile-helper")
            }
            source = try OpenSlideTileSource(
                slide: slide,
                helperURL: helperURL,
                tileSize: 512,
                workerCount: 3
            )
        }
        return try TileRenderSession(source: source, cacheDirectory: cacheDirectory)
    }

    private func session(for slideID: UUID) async throws -> TileRenderSession {
        if let cached = sessionsBySlideID[slideID] { return cached }
        guard let slide = slides.first(where: { $0.id == slideID }) else {
            throw SlideTileError.invalidData("未找到分析切片")
        }
        let session = try await Task.detached(priority: .userInitiated) {
            try Self.makeSession(for: slide)
        }.value
        sessionsBySlideID[slideID] = session
        initializeAliases(for: slideID, descriptor: session.descriptor)
        initializeAnalysisDefaults(for: slideID, descriptor: session.descriptor)
        return session
    }

    private func initializeAliases(for slideID: UUID, descriptor: SlideTileSourceDescriptor) {
        var aliases = channelAliasesBySlideID[slideID] ?? [:]
        for channel in descriptor.channels where aliases[channel.id] == nil {
            aliases[channel.id] = channel.name
        }
        channelAliasesBySlideID[slideID] = aliases
    }

    private func initializeAnalysisDefaults(for slideID: UUID, descriptor: SlideTileSourceDescriptor) {
        if analysisSlideAID == slideID {
            analysisROIAID = analysisROIAID ?? rois.first(where: { $0.slideID == slideID })?.id
            analysisChannelAID = analysisChannelAID ?? descriptor.channels.first?.id
        }
        if analysisSlideBID == slideID {
            analysisROIBID = analysisROIBID ?? rois.first(where: { $0.slideID == slideID })?.id
            analysisChannelBID = analysisChannelBID ?? descriptor.channels.first?.id
        }
    }

    var roisForSelectedSlide: [SquareROIRecord] {
        guard let selectedSlideID else { return [] }
        return rois.filter { $0.slideID == selectedSlideID }
    }

    func rois(for slideID: UUID?) -> [SquareROIRecord] {
        guard let slideID else { return [] }
        return rois.filter { $0.slideID == slideID }
    }

    func channels(for slideID: UUID?) -> [SlideTileChannelDescriptor] {
        guard let slideID else { return [] }
        return sessionsBySlideID[slideID]?.descriptor.channels ?? []
    }

    func channelAlias(slideID: UUID, channelID: String, fallback: String) -> String {
        channelAliasesBySlideID[slideID]?[channelID] ?? fallback
    }

    func setChannelAlias(slideID: UUID, channelID: String, alias: String) {
        var aliases = channelAliasesBySlideID[slideID] ?? [:]
        aliases[channelID] = alias
        channelAliasesBySlideID[slideID] = aliases
        objectWillChange.send()
    }

    func beginSquareROIPlacement() {
        guard tileDescriptor?.micronsPerPixelX != nil else {
            importMessages = ["当前切片缺少 µm/px 标定，不能创建物理尺寸 ROI。"]
            return
        }
        isPlacingSquareROI = true
    }

    func cancelSquareROIPlacement() {
        isPlacingSquareROI = false
    }

    func placeSquareROI(from start: CGPoint, to end: CGPoint, in size: CGSize) {
        guard isPlacingSquareROI,
              let slideID = selectedSlideID,
              let descriptor = tileDescriptor,
              let visible = visibleViewportRect,
              let mppX = descriptor.micronsPerPixelX,
              let mppY = descriptor.micronsPerPixelY,
              size.width > 0,
              size.height > 0 else { return }
        let startWorldX = visible.x + Double(start.x / size.width) * visible.width
        let startWorldY = visible.y + Double(start.y / size.height) * visible.height
        let endWorldX = visible.x + Double(end.x / size.width) * visible.width
        let endWorldY = visible.y + Double(end.y / size.height) * visible.height
        let physicalWidth = abs(endWorldX - startWorldX) * mppX
        let physicalHeight = abs(endWorldY - startWorldY) * mppY
        let maximumSide = min(
            Double(descriptor.levelZeroWidth) * mppX,
            Double(descriptor.levelZeroHeight) * mppY
        )
        let sideMicrons = min(max(max(physicalWidth, physicalHeight), 5), maximumSide)
        let worldX = (startWorldX + endWorldX) / 2
        let worldY = (startWorldY + endWorldY) / 2
        let roi = SquareROIRecord(
            slideID: slideID,
            name: "ROI \(rois.filter { $0.slideID == slideID }.count + 1)",
            centerX: min(max(worldX / Double(descriptor.levelZeroWidth), 0), 1),
            centerY: min(max(worldY / Double(descriptor.levelZeroHeight), 0), 1),
            sideMicrons: sideMicrons
        )
        rois.append(roi)
        roiSideMicrons = sideMicrons
        selectedROIID = roi.id
        if analysisSlideAID == slideID, analysisROIAID == nil { analysisROIAID = roi.id }
        if analysisSlideBID == slideID, analysisROIBID == nil { analysisROIBID = roi.id }
        isPlacingSquareROI = false
    }

    func moveSelectedROI(byScreenDelta delta: CGSize, in size: CGSize) {
        guard let selectedROIID,
              let index = rois.firstIndex(where: { $0.id == selectedROIID }),
              rois[index].slideID == selectedSlideID,
              let descriptor = tileDescriptor,
              let visible = visibleViewportRect,
              let mppX = descriptor.micronsPerPixelX,
              let mppY = descriptor.micronsPerPixelY,
              size.width > 0,
              size.height > 0,
              let geometry = try? SlideGeometry(
                width: descriptor.levelZeroWidth,
                height: descriptor.levelZeroHeight
              ) else { return }
        let deltaX = Double(delta.width / size.width) * visible.width
            / Double(descriptor.levelZeroWidth)
        let deltaY = Double(delta.height / size.height) * visible.height
            / Double(descriptor.levelZeroHeight)
        let center = SquareROIBounds.clampedNormalizedCenter(
            x: rois[index].centerX + deltaX,
            y: rois[index].centerY + deltaY,
            sideMicrons: rois[index].sideMicrons,
            slide: geometry,
            micronsPerPixelX: mppX,
            micronsPerPixelY: mppY
        )
        rois[index].centerX = center.x
        rois[index].centerY = center.y
    }

    func copySelectedROI(to targetSlideID: UUID?) {
        guard let selectedROIID,
              let source = rois.first(where: { $0.id == selectedROIID }),
              let targetSlideID,
              slides.contains(where: { $0.id == targetSlideID }) else {
            importMessages = ["请选择要复制到的目标切片。"]
            return
        }
        let copiesOnTarget = rois.filter { $0.slideID == targetSlideID }.count
        var centerX = source.centerX
        var centerY = source.centerY
        if targetSlideID == source.slideID,
           let descriptor = sessionsBySlideID[targetSlideID]?.descriptor,
           let mppX = descriptor.micronsPerPixelX,
           let mppY = descriptor.micronsPerPixelY {
            let offsetX = source.sideMicrons / mppX / Double(descriptor.levelZeroWidth) * 0.18
            let offsetY = source.sideMicrons / mppY / Double(descriptor.levelZeroHeight) * 0.18
            centerX = min(max(centerX + offsetX, 0), 1)
            centerY = min(max(centerY + offsetY, 0), 1)
        }
        let copy = SquareROIRecord(
            slideID: targetSlideID,
            name: "ROI \(copiesOnTarget + 1)（复制）",
            centerX: centerX,
            centerY: centerY,
            sideMicrons: source.sideMicrons
        )
        rois.append(copy)
        if targetSlideID == selectedSlideID {
            self.selectedROIID = copy.id
        }
        if analysisSlideAID == targetSlideID, analysisROIAID == nil { analysisROIAID = copy.id }
        if analysisSlideBID == targetSlideID, analysisROIBID == nil { analysisROIBID = copy.id }
    }

    func deleteSelectedROI() {
        guard let selectedROIID else { return }
        rois.removeAll { $0.id == selectedROIID }
        if analysisROIAID == selectedROIID { analysisROIAID = nil }
        if analysisROIBID == selectedROIID { analysisROIBID = nil }
        self.selectedROIID = roisForSelectedSlide.first?.id
    }

    func updateSelectedROISide(_ microns: Double) {
        guard let selectedROIID,
              let index = rois.firstIndex(where: { $0.id == selectedROIID }) else { return }
        let sourceROI = rois[index]
        let maximumSide: Double
        if let descriptor = sessionsBySlideID[sourceROI.slideID]?.descriptor,
           let mppX = descriptor.micronsPerPixelX,
           let mppY = descriptor.micronsPerPixelY {
            maximumSide = min(
                Double(descriptor.levelZeroWidth) * mppX,
                Double(descriptor.levelZeroHeight) * mppY
            )
        } else {
            maximumSide = .greatestFiniteMagnitude
        }
        let value = min(max(microns, 5), maximumSide)
        rois[index].sideMicrons = value
        roiSideMicrons = value
    }

    func selectAnalysisSlide(_ slot: AnalysisSlot, slideID: UUID?) {
        switch slot {
        case .a:
            analysisSlideAID = slideID
            analysisROIAID = rois(for: slideID).first?.id
            analysisChannelAID = nil
        case .b:
            analysisSlideBID = slideID
            analysisROIBID = rois(for: slideID).first?.id
            analysisChannelBID = nil
        }
        guard let slideID else { return }
        Task {
            do {
                _ = try await session(for: slideID)
            } catch {
                importMessages = [error.localizedDescription]
            }
        }
    }

    func runComparisonAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisResults = []
        Task {
            do {
                let resultA = try await analyzeSlot(
                    label: "A",
                    slideID: analysisSlideAID,
                    roiID: analysisROIAID,
                    channelID: analysisChannelAID
                )
                let resultB = try await analyzeSlot(
                    label: "B",
                    slideID: analysisSlideBID,
                    roiID: analysisROIBID,
                    channelID: analysisChannelBID
                )
                analysisResults = [resultA, resultB]
                isAnalyzing = false
            } catch {
                isAnalyzing = false
                importMessages = [error.localizedDescription]
            }
        }
    }

    private func analyzeSlot(
        label: String,
        slideID: UUID?,
        roiID: UUID?,
        channelID: String?
    ) async throws -> ROIAnalysisResult {
        guard let slideID,
              let roiID,
              let channelID,
              let slide = slides.first(where: { $0.id == slideID }),
              let roi = rois.first(where: { $0.id == roiID && $0.slideID == slideID }) else {
            throw SlideTileError.invalidData("请完整选择图 \(label) 的切片、ROI 和通道")
        }
        let session = try await session(for: slideID)
        guard let channel = session.descriptor.channels.first(where: { $0.id == channelID }) else {
            throw SlideTileError.invalidData("图 \(label) 的通道不存在")
        }
        return try await ROIAnalysisEngine.analyze(
            slot: label,
            slide: slide,
            roi: roi,
            channelID: channelID,
            channelName: channelAlias(
                slideID: slideID,
                channelID: channelID,
                fallback: channel.name
            ),
            session: session
        )
    }

    func exportAnalysisCSV() {
        guard analysisResults.count == 2 else {
            importMessages = ["请先完成 A/B 分析。"]
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "PathoScope_ROI_A-B_单通道定量.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = [
            "slot", "slide", "roi", "roi_side_um", "roi_area_um2", "channel",
            "pixel_count", "raw_mean_au", "raw_median_au", "integrated_intensity_au_um2",
            "background_pixel_count", "background_mean_au", "background_corrected_mean_au",
            "background_outer_scale", "source", "display_adjustments_applied"
        ].joined(separator: ",")
        let rows = analysisResults.map { result in
            let stats = result.statistics
            return [
                result.slot,
                csv(result.slideName),
                csv(result.roiName),
                String(format: "%.3f", result.sideMicrons),
                String(format: "%.3f", result.areaSquareMicrons),
                csv(result.channelName),
                "\(stats.raw.pixelCount)",
                String(format: "%.6f", stats.raw.mean),
                String(format: "%.6f", stats.raw.median),
                String(format: "%.6f", stats.raw.integratedIntensity),
                "\(stats.backgroundPixelCount)",
                String(format: "%.6f", stats.backgroundMean),
                String(format: "%.6f", stats.backgroundCorrectedMean),
                String(format: "%.2f", result.backgroundOuterScale),
                "level-0 stored channel",
                "false"
            ].joined(separator: ",")
        }
        do {
            try ([header] + rows).joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            importMessages = [error.localizedDescription]
        }
    }

    func exportSelectedROI(format: ROIExportFormat) {
        guard let slide = selectedSlide,
              let selectedROIID,
              let roi = rois.first(where: { $0.id == selectedROIID }),
              let session = tileSession else {
            importMessages = ["请先选择一个 ROI。"]
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .png ? [.png] : [.tiff]
        panel.nameFieldStringValue = "\(slide.displayName)_\(roi.name)_发表截图.\(format.pathExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let aliases = channelAliasesBySlideID[slide.id] ?? [:]
        Task {
            do {
                let data = try await ROIPublicationRenderer.render(
                    slideName: slide.displayName,
                    roi: roi,
                    session: session,
                    channelSettings: channelSettings,
                    channelAliases: aliases,
                    format: format
                )
                try data.write(to: url, options: .atomic)
            } catch {
                importMessages = [error.localizedDescription]
            }
        }
    }

    private func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func setChannelVisible(_ id: String, _ isVisible: Bool) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].isVisible = isVisible
    }

    func setChannelBrightness(_ id: String, _ brightness: Double) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].brightness = min(max(brightness, -1), 1)
    }

    func setChannelContrast(_ id: String, _ contrast: Double) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].contrast = min(max(contrast, 0.25), 4)
    }

    func setChannelBlack(_ id: String, _ black: Double) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        let value = min(max(black, 0), 0.99)
        channelSettings[index].black = value
        if channelSettings[index].white <= value {
            channelSettings[index].white = min(1, value + 0.01)
        }
    }

    func setChannelWhite(_ id: String, _ white: Double) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].white = min(
            max(white, channelSettings[index].black + 0.01),
            1
        )
    }

    func setChannelGamma(_ id: String, _ gamma: Double) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].gamma = min(max(gamma, 0.1), 4)
    }

    func setChannelLUT(_ id: String, _ preset: ChannelLUTPreset) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }) else { return }
        channelSettings[index].red = preset.red
        channelSettings[index].green = preset.green
        channelSettings[index].blue = preset.blue
    }

    func showAllChannels() {
        for index in channelSettings.indices {
            channelSettings[index].isVisible = true
        }
    }

    func showOnlyDAPI() {
        for index in channelSettings.indices {
            channelSettings[index].isVisible =
                channelSettings[index].name.localizedCaseInsensitiveContains("DAPI")
        }
    }

    func resetChannel(_ id: String) {
        guard let index = channelSettings.firstIndex(where: { $0.id == id }),
              let channel = tileDescriptor?.channels.first(where: { $0.id == id }) else {
            return
        }
        channelSettings[index].red = channel.red
        channelSettings[index].green = channel.green
        channelSettings[index].blue = channel.blue
        channelSettings[index].brightness = 0
        channelSettings[index].contrast = 1
        channelSettings[index].black = channel.defaultBlack
        channelSettings[index].white = channel.defaultWhite
        channelSettings[index].gamma = channel.defaultGamma
    }

    func resetAllChannels() {
        guard let descriptor = tileDescriptor else { return }
        configureChannels(descriptor: descriptor)
    }
}
