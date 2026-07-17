import SwiftUI
import UniformTypeIdentifiers
import PathoScopeCore

private enum InspectorMode: String, CaseIterable, Identifiable {
    case channels = "通道"
    case roi = "ROI"
    case analysis = "分析"
    var id: Self { self }
}

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var isDropTarget = false
    @State private var inspectorMode: InspectorMode = .channels
    @State private var showsSlideSidebar = true
    @State private var showsInspector = true
    @State private var transientMagnification: CGFloat = 1
    @State private var transientPan: CGSize = .zero
    @State private var roiDragStart: CGPoint?
    @State private var roiDragCurrent: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                if showsSlideSidebar {
                    slideList
                        .frame(
                            minWidth: 180,
                            idealWidth: 210,
                            maxWidth: 260,
                            maxHeight: .infinity
                        )
                }
                viewer
                    .frame(minWidth: 520, maxHeight: .infinity)
                if showsInspector {
                    inspector
                        .frame(
                            minWidth: 230,
                            idealWidth: 260,
                            maxWidth: 320,
                            maxHeight: .infinity
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $workspace.showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { workspace.importURLs(urls) }
            if case .failure(let error) = result { workspace.importMessages = [error.localizedDescription] }
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.importURLs(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .onOpenURL { url in
            workspace.importURLs([url])
        }
        .alert("部分文件未打开", isPresented: Binding(
            get: { !workspace.importMessages.isEmpty },
            set: { if !$0 { workspace.importMessages = [] } }
        )) {
            Button("知道了") { workspace.importMessages = [] }
        } message: {
            Text(workspace.importMessages.joined(separator: "\n"))
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { workspace.showImporter = true } label: {
                Label("打开", systemImage: "folder")
            }
            Divider().frame(height: 18)
            Menu {
                Toggle("显示左侧切片栏", isOn: $showsSlideSidebar)
                Toggle("显示右侧功能栏", isOn: $showsInspector)
                Divider()
                Button("全部显示") {
                    showsSlideSidebar = true
                    showsInspector = true
                }
                Button("只看图像") {
                    showsSlideSidebar = false
                    showsInspector = false
                }
            } label: {
                Label("布局", systemImage: "rectangle.split.2x1")
            }
            .help("分别显示或隐藏左侧切片栏与右侧功能栏")
            Button("同步", systemImage: "link") { }
            Spacer()
            Button("截图", systemImage: "camera") {
                inspectorMode = .roi
                workspace.exportSelectedROI(format: .png)
            }
            Button("导出", systemImage: "square.and.arrow.up") {
                inspectorMode = .analysis
                workspace.exportAnalysisCSV()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var slideList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("切片").font(.headline).padding(.horizontal, 12).padding(.top, 12)
            if workspace.slides.isEmpty {
                Text("尚未打开切片")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(workspace.slides, selection: Binding(
                    get: { workspace.selectedSlideID },
                    set: {
                        resetViewport()
                        workspace.selectSlide($0)
                    }
                )) { slide in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(slide.displayName).lineLimit(2)
                        Text(slide.format.rawValue.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(slide.id)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.regularMaterial)
    }

    private var viewer: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if workspace.slides.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
                    Text("将 MRXS、SVS 或其他切片拖到这里")
                        .font(.title3.weight(.medium))
                    Text("MRXS 会自动链接同名伴随目录")
                        .foregroundStyle(.secondary)
                    Button("选择文件") { workspace.showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isDropTarget ? Color.accentColor : .secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 2, dash: [8]))
                )
            } else if let session = workspace.tileSession {
                GeometryReader { proxy in
                    ZStack {
                        Color.black
                        MetalSlideCanvas(
                            session: session,
                            centerX: workspace.viewportCenterX,
                            centerY: workspace.viewportCenterY,
                            zoom: workspace.viewportZoom,
                            transientMagnification: transientMagnification,
                            transientPan: transientPan,
                            viewportSize: proxy.size,
                            channelSettings: workspace.channelSettings
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)

                        TrackpadGestureBridge(
                            selectedROIRect: selectedROI.flatMap { roiScreenRect($0, in: proxy.size) },
                            isROIPlacementActive: workspace.isPlacingSquareROI,
                            onMagnificationChanged: { value in
                                transientMagnification = value
                            },
                            onMagnificationEnded: { value in
                                workspace.zoom(by: Double(value))
                                transientMagnification = 1
                            },
                            onPanChanged: { value in
                                transientPan = value
                            },
                            onPanEnded: { value in
                                workspace.pan(
                                    viewportFractionDX:
                                        -Double(value.width / max(proxy.size.width, 1)),
                                    viewportFractionDY:
                                        -Double(value.height / max(proxy.size.height, 1))
                                )
                                transientPan = .zero
                            },
                            onROIMoveChanged: { delta in
                                workspace.moveSelectedROI(byScreenDelta: delta, in: proxy.size)
                            },
                            onROIMoveEnded: {},
                            onReset: {
                                resetViewport()
                                workspace.resetViewport()
                            }
                        )

                        roiOverlay(in: proxy.size)

                        scaleBar(in: proxy.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(16)

                        viewerControls
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 14)
                    }
                    .clipped()
                    .onAppear {
                        workspace.updateViewerSize(proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        workspace.updateViewerSize(size)
                    }
                    .onChange(of: workspace.previewRevision) { _, _ in
                        resetViewport()
                    }
                }
            } else if workspace.isLoadingPreview {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在读取切片预览…")
                    Text(workspace.selectedSlide?.displayName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let message = workspace.previewError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("切片读取失败").font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("重新加载") { workspace.reloadPreview() }
                }
            } else {
                Text("请选择左侧切片")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var viewerControls: some View {
        HStack(spacing: 8) {
            Button { workspace.zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Text(String(format: "%.1f×", workspace.viewportZoom))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)
            Button { workspace.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
            Divider().frame(height: 16)
            if let mpp = workspace.effectiveMicronsPerPixel {
                Text(String(format: "%.3f µm/px", mpp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider().frame(height: 16)
            }
            Button("适合窗口") { workspace.resetViewport() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func scaleBar(in availableSize: CGSize) -> some View {
        if let micronsPerPixel = workspace.levelZeroMicronsPerPixel,
           let visibleRect = workspace.visibleViewportRect,
           visibleRect.width > 0 {
            let displayedScale = max(
                0.000_001,
                availableSize.width / visibleRect.width * transientMagnification
            )
            let maximumPoints = min(150, max(70, availableSize.width * 0.22))
            if let measurement = ScaleBarCalculator.measurement(
                micronsPerImagePixel: micronsPerPixel,
                pointsPerImagePixel: displayedScale,
                maximumPoints: maximumPoints
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(measurement.label)
                        .font(.caption.monospacedDigit().weight(.semibold))
                    ZStack {
                        Rectangle().frame(height: 2)
                        HStack(spacing: 0) {
                            Rectangle().frame(width: 2, height: 8)
                            Spacer(minLength: 0)
                            Rectangle().frame(width: 2, height: 8)
                        }
                    }
                    .frame(width: measurement.points, height: 8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("比例尺 \(measurement.label)")
            }
        }
    }

    private func resetViewport() {
        transientMagnification = 1
        transientPan = .zero
    }

    private var inspector: some View {
        VStack(spacing: 12) {
            Picker("功能", selection: $inspectorMode) {
                ForEach(InspectorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)

            Group {
                switch inspectorMode {
                case .channels:
                    ScrollView { displayControls }
                case .roi:
                    ScrollView { roiControls }
                case .analysis:
                    ScrollView { analysisControls }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func roiOverlay(in size: CGSize) -> some View {
        ZStack {
            ForEach(workspace.roisForSelectedSlide) { roi in
                if let rect = roiScreenRect(roi, in: size) {
                    Rectangle()
                        .stroke(
                            roi.id == workspace.selectedROIID ? Color.yellow : Color.white,
                            style: StrokeStyle(lineWidth: roi.id == workspace.selectedROIID ? 2.5 : 1.5,
                                               dash: roi.id == workspace.selectedROIID ? [] : [6, 4])
                        )
                        .background(Color.yellow.opacity(roi.id == workspace.selectedROIID ? 0.05 : 0))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }

            if workspace.isPlacingSquareROI {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .local)
                            .onChanged { value in
                                roiDragStart = value.startLocation
                                roiDragCurrent = value.location
                            }
                            .onEnded { value in
                                workspace.placeSquareROI(
                                    from: value.startLocation,
                                    to: value.location,
                                    in: size
                                )
                                roiDragStart = nil
                                roiDragCurrent = nil
                            }
                    )
                if let preview = roiDragPreview(in: size) {
                    Rectangle()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                        .background(Color.yellow.opacity(0.08))
                        .frame(width: preview.rect.width, height: preview.rect.height)
                        .position(x: preview.rect.midX, y: preview.rect.midY)
                        .allowsHitTesting(false)
                    Text(String(format: "%.0f µm", preview.sideMicrons))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.yellow, in: Capsule())
                        .position(x: preview.rect.midX, y: max(14, preview.rect.minY - 15))
                        .allowsHitTesting(false)
                }
                VStack(spacing: 5) {
                    Label("按住并拖拽绘制正方形 ROI", systemImage: "square.dashed")
                        .font(.callout.weight(.semibold))
                    Text("松开完成 · 边长实时按 µm 显示")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.72), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(workspace.isPlacingSquareROI)
    }

    private func roiDragPreview(in size: CGSize) -> (rect: CGRect, sideMicrons: Double)? {
        guard let start = roiDragStart,
              let current = roiDragCurrent,
              let descriptor = workspace.tileDescriptor,
              let visible = workspace.visibleViewportRect,
              let mppX = descriptor.micronsPerPixelX,
              let mppY = descriptor.micronsPerPixelY,
              visible.width > 0,
              visible.height > 0 else { return nil }
        let physicalWidth = abs(Double(current.x - start.x) / size.width * visible.width) * mppX
        let physicalHeight = abs(Double(current.y - start.y) / size.height * visible.height) * mppY
        let maximumSide = min(
            Double(descriptor.levelZeroWidth) * mppX,
            Double(descriptor.levelZeroHeight) * mppY
        )
        let side = min(max(max(physicalWidth, physicalHeight), 5), maximumSide)
        let screenWidth = side / mppX / visible.width * size.width
        let screenHeight = side / mppY / visible.height * size.height
        let center = CGPoint(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
        return (
            CGRect(
                x: center.x - screenWidth / 2,
                y: center.y - screenHeight / 2,
                width: screenWidth,
                height: screenHeight
            ),
            side
        )
    }

    private func roiScreenRect(_ roi: SquareROIRecord, in size: CGSize) -> CGRect? {
        guard let descriptor = workspace.tileDescriptor,
              let visible = workspace.visibleViewportRect,
              let pixelRect = roi.pixelRect(descriptor: descriptor),
              visible.width > 0,
              visible.height > 0 else { return nil }
        let x = (pixelRect.minX - visible.x) / visible.width * size.width
        let y = (pixelRect.minY - visible.y) / visible.height * size.height
        let width = pixelRect.width / visible.width * size.width
        let height = pixelRect.height / visible.height * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var roiControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("正方形 ROI 截图") {
                VStack(alignment: .leading, spacing: 10) {
                    if workspace.isPlacingSquareROI {
                        Button("取消绘制", role: .cancel) {
                            roiDragStart = nil
                            roiDragCurrent = nil
                            workspace.cancelSquareROIPlacement()
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            workspace.beginSquareROIPlacement()
                        } label: {
                            Label("在画布拖拽绘制", systemImage: "square.dashed")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                    Text("想画多大就拖多大；ROI 以 level-0 坐标和物理尺寸保存，缩放不会改变区域。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }

            GroupBox("当前切片 ROI") {
                VStack(alignment: .leading, spacing: 9) {
                    if workspace.roisForSelectedSlide.isEmpty {
                        Text("尚未创建 ROI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("选择", selection: $workspace.selectedROIID) {
                            ForEach(workspace.roisForSelectedSlide) { roi in
                                Text("\(roi.name) · \(Int(roi.sideMicrons)) µm")
                                    .tag(Optional(roi.id))
                            }
                        }
                        if let selected = selectedROI {
                            HStack {
                                Text("边长")
                                Spacer()
                                TextField("µm", value: Binding(
                                    get: { selected.sideMicrons },
                                    set: { workspace.updateSelectedROISide($0) }
                                ), format: .number.precision(.fractionLength(0)))
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                                Text("µm").foregroundStyle(.secondary)
                            }
                            Button("删除所选 ROI", role: .destructive) {
                                workspace.deleteSelectedROI()
                            }
                            Divider()
                            Picker("复制到", selection: $workspace.roiCopyTargetSlideID) {
                                ForEach(workspace.slides) { slide in
                                    Text(slide.id == workspace.selectedSlideID
                                         ? "本切片 · \(slide.displayName)"
                                         : slide.displayName)
                                        .tag(Optional(slide.id))
                                }
                            }
                            Button {
                                workspace.copySelectedROI(to: workspace.roiCopyTargetSlideID)
                            } label: {
                                Label("复制所选 ROI", systemImage: "plus.square.on.square")
                            }
                        }
                    }
                }
                .padding(.vertical, 5)
            }

            GroupBox("发表截图标注") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("通道名称可改为真实 marker，例如 SPorange → SPHK1。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let slideID = workspace.selectedSlideID {
                        ForEach(workspace.channelSettings) { channel in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color(red: channel.red, green: channel.green, blue: channel.blue))
                                    .frame(width: 9, height: 9)
                                TextField(channel.name, text: Binding(
                                    get: {
                                        workspace.channelAlias(
                                            slideID: slideID,
                                            channelID: channel.id,
                                            fallback: channel.name
                                        )
                                    },
                                    set: { workspace.setChannelAlias(slideID: slideID, channelID: channel.id, alias: $0) }
                                ))
                            }
                        }
                    }
                    HStack {
                        Button("PNG") { workspace.exportSelectedROI(format: .png) }
                        Button("TIFF · 600 dpi") { workspace.exportSelectedROI(format: .tiff) }
                    }
                    .disabled(selectedROI == nil)
                    Text("导出 1600×1600 px，自动加入放大的彩色通道标签和比例尺，不显示样本名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("选中 ROI 后，可用触控板三指拖移；拖动只移动 ROI，物理边长保持不变。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var selectedROI: SquareROIRecord? {
        guard let id = workspace.selectedROIID else { return nil }
        return workspace.rois.first(where: { $0.id == id })
    }

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            analysisSlotCard(
                label: "A",
                slideID: Binding(
                    get: { workspace.analysisSlideAID },
                    set: { workspace.selectAnalysisSlide(.a, slideID: $0) }
                ),
                roiID: $workspace.analysisROIAID,
                channelID: $workspace.analysisChannelAID
            )
            analysisSlotCard(
                label: "B",
                slideID: Binding(
                    get: { workspace.analysisSlideBID },
                    set: { workspace.selectAnalysisSlide(.b, slideID: $0) }
                ),
                roiID: $workspace.analysisROIBID,
                channelID: $workspace.analysisChannelBID
            )

            Button {
                workspace.runComparisonAnalysis()
            } label: {
                if workspace.isAnalyzing {
                    HStack { ProgressView().controlSize(.small); Text("正在读取原始通道…") }
                } else {
                    Label("计算 A / B", systemImage: "function")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.isAnalyzing)
            .frame(maxWidth: .infinity)

            if !workspace.analysisResults.isEmpty {
                GroupBox("结果 · AU") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(workspace.analysisResults) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("图 \(result.slot) · \(result.channelName)")
                                    .font(.subheadline.weight(.semibold))
                                HStack(alignment: .firstTextBaseline) {
                                    Text("背景校正 mean")
                                    Spacer()
                                    Text(String(format: "%.3f", result.statistics.backgroundCorrectedMean))
                                        .font(.title3.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                                resultLine("raw mean", result.statistics.raw.mean)
                                resultLine("median", result.statistics.raw.median)
                                resultLine("background", result.statistics.backgroundMean)
                                resultLine("integrated", result.statistics.raw.integratedIntensity)
                            }
                            if result.id != workspace.analysisResults.last?.id { Divider() }
                        }
                        Button("导出 CSV") { workspace.exportAnalysisCSV() }
                    }
                    .padding(.vertical, 5)
                }
            }

            GroupBox("定量口径") {
                Text("读取 level-0 存储通道；不应用 LUT、亮度、对比度或 Gamma。背景取 ROI 外、1.5× 外框内的方形环带。主比较值为 ROI raw mean − local background mean。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
            }
        }
    }

    private func analysisSlotCard(
        label: String,
        slideID: Binding<UUID?>,
        roiID: Binding<UUID?>,
        channelID: Binding<String?>
    ) -> some View {
        GroupBox("图 \(label)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("切片", selection: slideID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(workspace.slides) { slide in
                        Text(slide.displayName).tag(Optional(slide.id))
                    }
                }
                Picker("ROI", selection: roiID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(workspace.rois(for: slideID.wrappedValue)) { roi in
                        Text("\(roi.name) · \(Int(roi.sideMicrons)) µm").tag(Optional(roi.id))
                    }
                }
                Picker("通道", selection: channelID) {
                    Text("请选择").tag(Optional<String>.none)
                    ForEach(workspace.channels(for: slideID.wrappedValue), id: \.id) { channel in
                        Text(workspace.channelAlias(
                            slideID: slideID.wrappedValue ?? UUID(),
                            channelID: channel.id,
                            fallback: channel.name
                        )).tag(Optional(channel.id))
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    private func resultLine(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.3f", value)).monospacedDigit()
        }
        .font(.caption)
    }

    private var displayControls: some View {
        GroupBox("通道显示") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("全开") { workspace.showAllChannels() }
                    Button("仅 DAPI") { workspace.showOnlyDAPI() }
                    Spacer()
                    Button {
                        workspace.resetAllChannels()
                    } label: {
                        Label("全部重置", systemImage: "arrow.counterclockwise")
                    }
                    .help("恢复全部通道的显示、LUT、亮度、对比度、Black、White 和 Gamma 默认值")
                }

                Text(workspace.channelModeDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        workspace.hasExactMRXSChannels || workspace.hasExactSVSChannels
                            ? Color.green
                            : Color.orange
                    )

                if workspace.slides.isEmpty {
                    Text("打开切片后显示通道控制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if workspace.isLoadingPreview {
                    Text("正在读取通道…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if workspace.channelSettings.isEmpty {
                    Text("RGB 原色显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspace.channelSettings) { channel in
                        channelControl(channel)
                        if channel.id != workspace.channelSettings.last?.id { Divider() }
                    }
                }

                Divider()
                Text("显示曲线与 LUT 仅作用于屏幕，不改变原始像素和后续定量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private func channelControl(_ channel: ChannelDisplaySettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(red: channel.red, green: channel.green, blue: channel.blue))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                Toggle(channel.name, isOn: Binding(
                    get: { channel.isVisible },
                    set: { workspace.setChannelVisible(channel.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer(minLength: 4)
                Menu {
                    ForEach(ChannelLUTPreset.all) { preset in
                        Button {
                            workspace.setChannelLUT(channel.id, preset)
                        } label: {
                            Label(
                                preset.name,
                                systemImage: isCurrentLUT(preset, for: channel)
                                    ? "checkmark.circle.fill"
                                    : "circle.fill"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(
                                red: channel.red,
                                green: channel.green,
                                blue: channel.blue
                            ))
                            .frame(width: 11, height: 11)
                        Text("LUT")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("颜色查找表")
            }

            HStack(spacing: 7) {
                Text("亮度").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.brightness },
                    set: { workspace.setChannelBrightness(channel.id, $0) }
                ), in: -1...1)
                Text(String(format: "%+.2f", channel.brightness))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Text("对比").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.contrast },
                    set: { workspace.setChannelContrast(channel.id, $0) }
                ), in: 0.25...4)
                Text(String(format: "%.2f", channel.contrast))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Text("Black").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.black },
                    set: { workspace.setChannelBlack(channel.id, $0) }
                ), in: 0...0.95)
                Text(String(format: "%.2f", channel.black))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Text("White").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.white },
                    set: { workspace.setChannelWhite(channel.id, $0) }
                ), in: 0.05...1)
                Text(String(format: "%.2f", channel.white))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Text("Gamma").font(.caption).frame(width: 42, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.gamma },
                    set: { workspace.setChannelGamma(channel.id, $0) }
                ), in: 0.1...4)
                Text(String(format: "%.2f", channel.gamma))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Spacer()
                Button("重置该通道") { workspace.resetChannel(channel.id) }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func isCurrentLUT(
        _ preset: ChannelLUTPreset,
        for channel: ChannelDisplaySettings
    ) -> Bool {
        abs(preset.red - channel.red) < 0.001
            && abs(preset.green - channel.green) < 0.001
            && abs(preset.blue - channel.blue) < 0.001
    }
}
