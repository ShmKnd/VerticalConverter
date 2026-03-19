//
//  ContentView.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
@preconcurrency import AVFoundation

/// macOS 14+: `.symbolEffect(.pulse)` を適用し、macOS 13 では何もしない。
private struct PulseEffectModifier: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.pulse, isActive: isActive)
        } else {
            content
        }
    }
}

/// ウィンドウの横幅を固定しつつ縦方向のリサイズだけ許可する
private struct WindowWidthConstrainer: NSViewRepresentable {
    private class WindowDelegateProxy: NSObject, NSWindowDelegate {
        weak var originalDelegate: NSWindowDelegate?

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 960
            let maxHeight = min(1040, screenHeight - 28)
            let clampedHeight = min(frameSize.height, maxHeight)
            return NSSize(width: 560, height: clampedHeight)
        }

        // 元のデリゲートへ他のメソッドを転送
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original = originalDelegate, original.responds(to: aSelector) {
                return original
            }
            return super.forwardingTarget(for: aSelector)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let proxy = WindowDelegateProxy()
            proxy.originalDelegate = window.delegate
            // proxy を window に retain させる
            objc_setAssociatedObject(window, "WindowDelegateProxy", proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = proxy
            window.minSize = NSSize(width: 560, height: 600)
            window.maxSize = NSSize(width: 560, height: min(1040, (NSScreen.main?.visibleFrame.height ?? 960) - 28))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isTargeted = false
    @State private var showingCropPreview: Bool = false

    var body: some View {
        ZStack {
            // Liquid Glass が映える鮮やかなグラデーション背景
            Color(nsColor: NSColor.windowBackgroundColor)
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // ヘッダー
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Vertical Converter")
                                .font(.title.bold())
                                .foregroundStyle(.primary)
                            #if EDITION_DEMO
                            Text("DEMO")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                            #endif
                        }
                        Text("Convert 16:9 → 9:16")
                            .font(.subheadline)
                            .foregroundStyle(Color.primary.opacity(0.75))
                        #if EDITION_DEMO
                        demoStatusLabel
                        #endif
                    }
                    .padding(.top, 14)

                    dropZone
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.isProcessing)
                    settingsPanel
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.isProcessing)
                    smartFramingPanel
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.isProcessing)
                    hdrPanel
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.isProcessing)
                    actionPanel
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
                .frame(width: 560)
            }
        }
        .background(WindowWidthConstrainer())
        .frame(
            minWidth: 560, idealWidth: 560, maxWidth: 560,
            minHeight: 600,
            idealHeight: min(1040, (NSScreen.main?.visibleFrame.height ?? 960) - 28),
            maxHeight: min(1040, (NSScreen.main?.visibleFrame.height ?? 960) - 28)
        )
        .sheet(isPresented: $showingCropPreview) {
            VStack(spacing: 0) {
                // ── ヘッダー ──
                HStack {
                    Text("Crop Preview")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showingCropPreview = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()

                // ── コンテンツ ──
                VStack(spacing: 12) {
                    CropPreviewView(
                        thumbnail: viewModel.thumbnail,
                        selection: $viewModel.letterboxMode,
                        cropPositionX: $viewModel.cropPositionX,
                        cropPositionY: $viewModel.cropPositionY
                    )

                    // ── クロップ位置スライダー (水平のみ表示、垂直は内部保持・UI非公開) ──
                    VStack(spacing: 8) {
                        Divider()
                            .overlay(Color.primary.opacity(0.18))
                        HStack(spacing: 8) {
                            Label("Center Position", systemImage: "arrow.left.and.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.primary.opacity(0.8))
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                                    viewModel.cropPositionX = 0.5
                                }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption)
                                .foregroundStyle(Color.primary.opacity(0.6))
                                .frame(width: 14)
                            Slider(value: $viewModel.cropPositionX, in: 0...1)
                                .tint(Color.primary.opacity(0.55))
                        }
                    }
                    .padding(.bottom, 4)
                    .opacity(viewModel.letterboxMode != .fitWidth ? 1.0 : 0.35)
                    .allowsHitTesting(viewModel.letterboxMode != .fitWidth)

                    // ── サムネイル時刻指定シーク ──
                    if viewModel.videoDuration > 0 {
                        VStack(spacing: 8) {
                            Divider()
                                .overlay(Color.primary.opacity(0.18))
                            HStack(spacing: 8) {
                                Label("Thumbnail Time", systemImage: "clock")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                                Spacer()
                                Text(formatSeconds(viewModel.thumbnailTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .frame(minWidth: 44, alignment: .trailing)
                            }
                            Slider(
                                value: $viewModel.thumbnailTime,
                                in: 0...max(viewModel.videoDuration - 0.066, 0.066),
                                onEditingChanged: { editing in
                                    if !editing {
                                        viewModel.generateThumbnailAtCurrentTime()
                                    }
                                }
                            )
                            .tint(Color.primary.opacity(0.55))
                        }
                        .padding(.bottom, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Demo Status Label

    #if EDITION_DEMO
    private var demoStatusLabel: some View {
        #if EDITION_DEMO
        let tracker = DemoUsageTracker.shared
        let remaining = tracker.remainingFreeEncodes
        #endif
        return Group {
            if remaining > 0 {
                Text("Full quality: \(remaining) encodes remaining")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.85))
            } else {
                Text("Trial expired — watermark applied")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.85))
            }
        }
    }
    #endif

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            // ── サムネイル背景（単体ファイル読み込み時のみ、文字UIの後ろにうっすら表示）──
            if let thumb = viewModel.thumbnail, !isTargeted, viewModel.selectedVideoURLs.count == 1 {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(0.50)
                    .blur(radius: 3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // UX: D&D 中は常にドロップ案内を表示（既存ファイルがある場合も同様）
            if isTargeted {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.primary)
                        .modifier(PulseEffectModifier(isActive: isTargeted))
                    Text("Drag & Drop")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    Button("Select File") {
                        viewModel.selectFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primary.opacity(0.2))
                }
                .padding()

            } else if viewModel.selectedVideoURLs.count > 1 {
                // ── バッチモード: 複数ファイル一覧 ──
                if viewModel.hasConverted {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.primary)
                        Text("\(viewModel.selectedVideoURLs.count) files converted")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Button("Select Another File") {
                            viewModel.selectedVideoURLs = []
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .underline()
                    }
                    .padding()
                } else {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 26))
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(viewModel.selectedVideoURLs.count) files queued")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Ready for batch conversion")
                                .font(.caption)
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }
                        Spacer()
                        Button("Clear") {
                            viewModel.selectedVideoURLs = []
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .underline()
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(viewModel.selectedVideoURLs, id: \.self) { url in
                                HStack(spacing: 6) {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.primary.opacity(0.5))
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(Color.primary.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 52)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                } // end else

            } else if let videoURL = viewModel.selectedVideoURL {
                // If file is selected but not yet converted, show a neutral file view.
                if viewModel.hasConverted {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.primary)
                        Text(videoURL.lastPathComponent)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Button("Select Another File") {
                            viewModel.selectedVideoURLs = []
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .underline()
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video")
                            .font(.system(size: 44))
                            .foregroundStyle(.primary)
                        Text(videoURL.lastPathComponent)
                            .font(.headline)
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Button("Select Another File") {
                            viewModel.selectedVideoURLs = []
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .underline()
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.primary)
                        .modifier(PulseEffectModifier(isActive: isTargeted))
                    Text("Drag & Drop")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    Button("Select File") {
                        viewModel.selectFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primary.opacity(0.2))
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 175)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26+→.glassEffect(in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isTargeted ? Color.primary.opacity(0.9) : Color.primary.opacity(0.25),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: viewModel.selectedVideoURLs.isEmpty ? [8, 4] : []
                    )
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            viewModel.handleDrop(providers: providers)
            return true
        }
        .animation(Animation.easeInOut(duration: 0.2), value: isTargeted)
        .overlay(alignment: .topTrailing) {
            Button(action: { showingCropPreview.toggle() }) {
                Text("Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(8)
            .disabled(viewModel.selectedVideoURL == nil || viewModel.selectedVideoURLs.count > 1)
            .opacity((viewModel.selectedVideoURL == nil || viewModel.selectedVideoURLs.count > 1) ? 0.35 : 1.0)
            // Note: Popover replaced by an in-window overlay to ensure the preview stays inside the window.
        }
    }

            // MARK: - Crop Preview Panel

    private var cropPreviewPanel: some View {
        Group {
            if viewModel.selectedVideoURL == nil {
                // Placeholder when no file selected
                VStack(spacing: 8) {
                    HStack {
                        Label("Crop Preview", systemImage: "crop")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    Text("Select a file to show the preview")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                CropPreviewView(
                    thumbnail: viewModel.thumbnail,
                    selection: $viewModel.letterboxMode,
                    cropPositionX: $viewModel.cropPositionX,
                    cropPositionY: $viewModel.cropPositionY
                )
            }
        }
    }

    // MARK: - Output Settings Panel

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            settingRow(label: "Resolution", icon: "aspectratio", tooltip: "Output resolution. 720p = 720×1280, 1080p = 1080×1920.") {
                SlidingPicker(
                    labels: VideoExportSettings.Resolution.allCases.map { $0.rawValue },
                    values: VideoExportSettings.Resolution.allCases,
                    selection: $viewModel.exportSettings.resolution
                )
            }
            panelDivider
            settingRow(label: "FPS", icon: "film.stack", tooltip: "Output frame rate. 'Src' preserves the original frame rate.") {
                SlidingPicker(
                    labels: VideoExportSettings.FrameRate.allCases.map { $0.displayLabel },
                    values: VideoExportSettings.FrameRate.allCases,
                    selection: $viewModel.exportSettings.frameRate
                )
            }
            panelDivider
            settingRow(label: "Codec", icon: "cpu", tooltip: "Video compression codec. VT variants use hardware acceleration.") {
                SlidingPicker(
                    labels: VideoExportSettings.Codec.allCases.map { $0.rawValue },
                    values: VideoExportSettings.Codec.allCases,
                    selection: $viewModel.exportSettings.codec,
                    isEnabled: { codec in
                        // VT バリアントはハードウェアが無ければグレーアウト
                        switch codec {
                        case .h264VT, .h265VT, .prores422VT:
                            return VideoProcessor.isHardwareEncoderAvailable(for: codec)
                        default:
                            return true
                        }
                    }
                )
            }
            panelDivider
            settingRow(label: "Container", icon: "doc.zipper", tooltip: "Output container format. Applies to HEVC only; H.264 is always MP4, ProRes always MOV.") {
                SlidingPicker(
                    labels: VideoExportSettings.ContainerFormat.allCases.map { $0.rawValue },
                    values: VideoExportSettings.ContainerFormat.allCases,
                    selection: $viewModel.exportSettings.containerFormat,
                    isEnabled: { _ in
                        // Container choice only applies to HEVC codecs.
                        // H.264 is always .mp4, ProRes is always .mov.
                        let codec = viewModel.exportSettings.codec
                        return codec == .h265 || codec == .h265VT
                    }
                )
            }
            panelDivider
            settingRow(label: "Bitrate", icon: "dial.min.fill", tooltip: "Target video bitrate in Mbps. Disabled for ProRes.") {
                SlidingPicker(
                    labels: [8, 10, 12].map { "\($0) Mbps" },
                    values: [8, 10, 12],
                    selection: $viewModel.exportSettings.bitrate,
                    isEnabled: { _ in
                        // ビットレートは ProRes を選択したときにグレーアウト
                        return viewModel.exportSettings.codec != .prores422VT
                    }
                )
            }
            panelDivider
            settingRow(label: "Bitrate Mode", icon: "slider.horizontal.3", tooltip: "VBR: variable bitrate, CBR: constant bitrate, ABR: average bitrate.") {
                SlidingPicker(
                    labels: VideoExportSettings.EncodingMode.allCases.map { $0.rawValue },
                    values: VideoExportSettings.EncodingMode.allCases,
                    selection: $viewModel.exportSettings.encodingMode,
                    isEnabled: { _ in
                        // ProRes 選択時は品質（エンコードモード）を無効化
                        return viewModel.exportSettings.codec != .prores422VT
                    }
                )
            }
            panelDivider
            settingRow(label: "Crop", icon: "crop", tooltip: "Crop region to fill the 9:16 frame from the 16:9 source.") {
                SlidingPicker(
                    labels: CustomVideoCompositionInstruction.LetterboxMode.allCases.map { $0.displayName },
                    values: CustomVideoCompositionInstruction.LetterboxMode.allCases,
                    selection: $viewModel.letterboxMode
                )
            }

            // When Smart Framing is enabled, the letterbox control is not applicable.
            // Visually de-emphasize and disable interaction to make that clear.
            .opacity(viewModel.smartFramingEnabled ? 0.35 : 1.0)
            .allowsHitTesting(!viewModel.smartFramingEnabled)

            panelDivider

            // ── クロップ位置スライダー（Crop行直下）──
            // fitWidth はソース幅＝出力幅なので水平クロップ不要 → グレーアウト
            // Smart Framing ON 時も非適用なのでグレーアウト
            settingRow(label: "Center Pos", icon: "arrow.left.and.right",
                       tooltip: "Horizontal crop center position. Disabled for Fit W (no horizontal crop needed).") {
                Slider(value: $viewModel.cropPositionX, in: 0...1)
                    .tint(Color.primary.opacity(0.55))
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        viewModel.cropPositionX = 0.5
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .opacity((viewModel.letterboxMode != .fitWidth && !viewModel.smartFramingEnabled && !viewModel.selectedVideoURLs.isEmpty) ? 1.0 : 0.35)
            .allowsHitTesting(viewModel.letterboxMode != .fitWidth && !viewModel.smartFramingEnabled && !viewModel.selectedVideoURLs.isEmpty)

            panelDivider

            settingRow(label: "Output", icon: "folder",
                       tooltip: "Output folder for exported files. Defaults to same folder as input.") {
                Button {
                    viewModel.selectOutputDirectory()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                        Text(viewModel.outputDirectoryURL?.lastPathComponent ?? "Same as Input")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                if viewModel.outputDirectoryURL != nil {
                    Button {
                        viewModel.outputDirectoryURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26+→.glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Smart Framing Panel (fixed height)

    private var smartFramingPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Smart Framing", systemImage: "person.crop.rectangle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $viewModel.smartFramingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            panelDivider
            // Follow Speed: always visible. When OFF, dim (no height change)
            settingRow(label: "Follow Speed", icon: "arrow.left.and.right", tooltip: "How quickly auto-framing follows subject movement.") {
                SlidingPicker(
                    labels: SmartFramingSettings.Smoothness.allCases.map { $0.rawValue },
                    values: SmartFramingSettings.Smoothness.allCases,
                    selection: $viewModel.smartFramingSmoothness
                )
            }
            .opacity(viewModel.smartFramingEnabled ? 1.0 : 0.35)
            .allowsHitTesting(viewModel.smartFramingEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26+→.glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - HDR -> SDR Panel

    private var isHDRAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    private var hdrPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HDR→SDR Conversion", systemImage: "display")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if !isHDRAvailable {
                    Text("macOS 14+")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: $viewModel.hdrConversionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!isHDRAvailable)
            }
            panelDivider
            settingRow(label: "Tone Map", icon: "camera.filters", tooltip: "HDR-to-SDR tone mapping style. Natural = neutral, Cinematic = high contrast.") {
                SlidingPicker(
                    labels: ["Natural", "Cinematic"],
                    values: [CustomVideoCompositionInstruction.ToneMappingMode.natural, CustomVideoCompositionInstruction.ToneMappingMode.cinematic],
                    selection: $viewModel.toneMappingMode
                )
            }
            .opacity(viewModel.hdrConversionEnabled ? 1.0 : 0.35)
            .allowsHitTesting(viewModel.hdrConversionEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .opacity(isHDRAvailable ? 1.0 : 0.5)
        .allowsHitTesting(isHDRAvailable)
    }

    // MARK: - アクションパネル

    private var actionPanel: some View {
        VStack(spacing: 14) {
            if viewModel.isProcessing {
                Button {
                    viewModel.cancelConversion()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel Conversion")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.65))
            } else {
                Button {
                    viewModel.convertVideo()
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        if viewModel.selectedVideoURLs.count > 1 {
                            Text("Start Batch Conversion (\(viewModel.selectedVideoURLs.count))")
                        } else {
                            Text("Start Conversion")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hue: 0.38, saturation: 0.75, brightness: 0.72))
                .disabled(viewModel.selectedVideoURLs.isEmpty)
            }

            // プログレス（常に表示。非処理時は淡く表示）
            VStack(spacing: 2) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if viewModel.isProcessing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                            .hidden()
                    }

                    Text(viewModel.phaseLabel)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(viewModel.isProcessing ? 0.85 : 0.35))

                    Spacer()

                    Text(String(format: "%.0f%%", viewModel.progress * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(viewModel.isProcessing ? 0.85 : 0.35))
                }

                ProgressView(value: viewModel.progress)
                    .tint(viewModel.isProcessing ? Color.primary : Color.primary.opacity(0.25))
            }
            .frame(height: 32)

            Text(viewModel.statusMessage.isEmpty ? " " : viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(viewModel.hasError ? Color.red : Color.primary.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 36) // 固定高さを確保して UI のジャンプを防止
            } // end progress + status VStack
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26 以降は下記に差し替え
        // .glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Panel Helpers

    private var panelDivider: some View {
        Divider()
            .overlay(Color.primary.opacity(0.18))
            .padding(.vertical, 6)
    }

    private func settingRow<Content: View>(
        label: String, icon: String,
        tooltip: String = "",
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 20, alignment: .center)
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(width: 115, alignment: .leading)

            picker()
        }
        .frame(minHeight: 30)
        .help(tooltip)
    }

    /// 秒数を "M:SS.t" 形式の文字列に変換するヒルパー
    private func formatSeconds(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let m = total / 60
        let s = total % 60
        let tenths = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", m, s, tenths)
    }
}

// MARK: - Helpers

private struct SlidingPicker<T: Hashable>: View {
    let labels: [String]
    let values: [T]
    @Binding var selection: T
    var isEnabled: ((T) -> Bool)? = nil
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { i in
                let isSelected = selection == values[i]
                let enabled = isEnabled?(values[i]) ?? true
                Button {
                    guard enabled else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        selection = values[i]
                    }
                } label: {
                    Text(labels[i])
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .animation(nil, value: isSelected)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(enabled ? 0.55 : 0.28))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.28))
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .opacity(enabled ? 1.0 : 0.45)
                .allowsHitTesting(enabled)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Crop Preview

private struct CropPreviewView: View {
    let thumbnail: NSImage?
    @Binding var selection: CustomVideoCompositionInstruction.LetterboxMode
    @Binding var cropPositionX: Double
    @Binding var cropPositionY: Double

    /// 下段 3列の実アイテム幅を測定して上段 2列のサイズ合わせに使用
    @State private var itemWidth: CGFloat = 0

    private let gridColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 12) {
            // ── 上段 2列・中央揃え（itemWidth = 下段の1列幅）──
            HStack(spacing: 12) {
                modeButton(.fitWidth)
                    .frame(width: itemWidth > 0 ? itemWidth : nil)
                modeButton(.fitHeight)
                    .frame(width: itemWidth > 0 ? itemWidth : nil)
            }

            // ── 下段 3列・アイテム幅を測定 ──
            LazyVGrid(columns: gridColumns, spacing: 12) {
                modeButton(.centerSquare)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { itemWidth = geo.size.width }
                                .onChange(of: geo.size.width) { newValue in itemWidth = newValue }
                        }
                    )
                modeButton(.centerPortrait4x3)
                modeButton(.centerPortrait3x4)
            }
        }
        // ensure top inset matches the close button so the title and xmark align
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func modeButton(_ mode: CustomVideoCompositionInstruction.LetterboxMode) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                selection = mode
            }
        }) {
            CropPreviewThumbnail(
                image: thumbnail,
                mode: mode,
                isSelected: selection == mode,
                cropPositionX: selection == mode ? cropPositionX : 0.5,
                cropPositionY: selection == mode ? cropPositionY : 0.5
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CropPreviewThumbnail: View {
    let image: NSImage?
    let mode: CustomVideoCompositionInstruction.LetterboxMode
    let isSelected: Bool
    var cropPositionX: Double = 0.5
    var cropPositionY: Double = 0.5

    var body: some View {
        ZStack {
            if let img = image {
                GeometryReader { geo in
                    let canvasSize = geo.size

                    ZStack {
                        // 1) blurred background fills the 9:16 canvas
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .clipped()
                            .blur(radius: 18)

                        // 2) cropped sharp image according to selected mode
                        croppedImage(img: img, canvasSize: canvasSize, mode: mode,
                                     cropPositionX: cropPositionX, cropPositionY: cropPositionY)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0/16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
    
    private func croppedImage(img: NSImage, canvasSize: CGSize,
                               mode: CustomVideoCompositionInstruction.LetterboxMode,
                               cropPositionX: Double = 0.5,
                               cropPositionY: Double = 0.5) -> some View {
        // Determine desired target aspect for cropping (width / height)
        let outputAspect: CGFloat = 9.0 / 16.0
        let targetAspect: CGFloat = {
            switch mode {
            case .fitWidth:  return outputAspect
            case .fitHeight: return outputAspect  // unused; handled separately below
            case .centerSquare: return 1.0
            case .centerPortrait4x3: return 3.0 / 4.0
            case .centerPortrait3x4: return 4.0 / 3.0
            }
        }()

        if mode == .fitWidth {
            // Fit the source width to the canvas width (no horizontal crop).
            let scale = canvasSize.width / img.size.width
            let scaledHeight = img.size.height * scale
            let posY = scaledHeight * 0.5 + (canvasSize.height - scaledHeight) * CGFloat(cropPositionY)
            return AnyView(
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: canvasSize.width, height: scaledHeight)
                    .clipped()
                    .position(x: canvasSize.width * 0.5, y: posY)
            )
        } else if mode == .fitHeight {
            // Fit the source height to the canvas height (left/right crop).
            let scale = canvasSize.height / img.size.height
            let scaledWidth = img.size.width * scale
            let posX = scaledWidth * 0.5 + (canvasSize.width - scaledWidth) * CGFloat(cropPositionX)
            return AnyView(
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: scaledWidth, height: canvasSize.height)
                    .clipped()
                    .position(x: posX, y: canvasSize.height * 0.5)
            )
        } else {
            // For center crop modes: scale image so the crop region fills canvas width,
            // then position to reflect the selected crop offset.
            let sourceAspect = img.size.width / img.size.height
            let cropW: CGFloat = sourceAspect > targetAspect ? img.size.height * targetAspect : img.size.width
            let cropH: CGFloat = sourceAspect > targetAspect ? img.size.height : img.size.width / targetAspect
            let scale = canvasSize.width / cropW
            let scaledImgW = img.size.width * scale
            let scaledImgH = img.size.height * scale
            let croppedHeight = cropH * scale

            // Canvas Y center of the cropped content (affected by cropPositionY)
            let contentCenterY = (canvasSize.height - croppedHeight) * CGFloat(cropPositionY) + croppedHeight * 0.5

            // Image center in canvas accounting for crop offset
            let imageCenterX: CGFloat
            let imageCenterY: CGFloat
            if sourceAspect > targetAspect {
                // Horizontal crop: shift image left/right
                let cropX = (img.size.width - cropW) * CGFloat(cropPositionX)
                imageCenterX = scaledImgW * 0.5 - cropX * scale
                imageCenterY = contentCenterY
            } else {
                // Vertical crop: shift image up/down
                let cropY = (img.size.height - cropH) * CGFloat(cropPositionY)
                imageCenterX = canvasSize.width * 0.5
                imageCenterY = scaledImgH * 0.5 - cropY * scale + (contentCenterY - croppedHeight * 0.5)
            }

            return AnyView(
                Image(nsImage: img)
                    .resizable()
                    .frame(width: scaledImgW, height: scaledImgH)
                    .position(x: imageCenterX, y: imageCenterY)
            )
        }
    }
}

@MainActor
class ContentViewModel: ObservableObject {

    // MARK: - Init (restore persisted settings)

    init() {
        restoreSettings()
    }

    // MARK: - ファイル選択（バッチ対応）

    /// 選択 / D&D されたファイル URL リスト（単体ファイルも含む）
    @Published var selectedVideoURLs: [URL] = [] {
        didSet {
            if selectedVideoURLs.isEmpty {
                self.thumbnail = nil
                self.videoDuration = 0.0
            } else {
                self.hasConverted = false
                self.thumbnailTime = 1.0
                self.cropPositionX = 0.5
                self.cropPositionY = 0.5
                generateThumbnail()
                loadVideoDuration()
            }
        }
    }

    /// 後方互換用: 先頭 URL（単体ファイルモードや UI 表示に使用）
    var selectedVideoURL: URL? { selectedVideoURLs.first }

    @Published var thumbnail: NSImage? = nil
    /// 動画の総デュレーション（秒）。0 はまだ取得できていないか不明。
    @Published var videoDuration: Double = 0.0
    /// プレビューでサムネイルを取得する時刻（秒）
    @Published var thumbnailTime: Double = 1.0
    @Published var exportSettings = VideoExportSettings() {
        didSet { saveSettings() }
    }
    @Published var hasConverted: Bool = false
    @Published var smartFramingEnabled: Bool = false {
        didSet { saveSettings() }
    }
    @Published var smartFramingSmoothness: SmartFramingSettings.Smoothness = .normal {
        didSet { saveSettings() }
    }
    @Published var letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth {
        didSet { saveSettings() }
    }
    /// クロップ領域の水平位置 (0=左端, 0.5=中央, 1=右端).  fitWidth 以外で有効。
    @Published var cropPositionX: Double = 0.5 {
        didSet { saveSettings() }
    }
    /// クロップ領域の垂直位置 (0=上端, 0.5=中央, 1=下端).  fitHeight 以外で有効。
    @Published var cropPositionY: Double = 0.5 {
        didSet { saveSettings() }
    }
    @Published var hdrConversionEnabled: Bool = false {
        didSet { saveSettings() }
    }
    @Published var toneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural {
        didSet { saveSettings() }
    }
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var phaseLabel: String = ""
    @Published var statusMessage: String = ""
    @Published var hasError: Bool = false
    /// サンドボックス環境で使用する出力先ディレクトリ（ユーザーが明示的に選択）
    @Published var outputDirectoryURL: URL? = nil {
        didSet { saveOutputDirectoryBookmark() }
    }

    private let videoProcessor = VideoProcessor()
    private var conversionTask: Task<Void, Never>?
    /// UserDefaults 復元中の無限ループを防止
    private var isRestoringSettings = false

    // MARK: - Settings Persistence (UserDefaults)

    private enum SettingsKey {
        static let resolution = "vc_resolution"
        static let frameRate = "vc_frameRate"
        static let codec = "vc_codec"
        static let container = "vc_container"
        static let bitrate = "vc_bitrate"
        static let encodingMode = "vc_encodingMode"
        static let cropMode = "vc_cropMode"
        static let cropPositionX = "vc_cropPositionX"
        static let smartFraming = "vc_smartFraming"
        static let smartFramingSmoothness = "vc_smartFramingSmoothness"
        static let hdrConversion = "vc_hdrConversion"
        static let toneMappingMode = "vc_toneMappingMode"
        static let outputDirBookmark = "vc_outputDirBookmark"
    }

    func restoreSettings() {
        isRestoringSettings = true
        defer { isRestoringSettings = false }
        let d = UserDefaults.standard

        // Export settings
        if let raw = d.string(forKey: SettingsKey.resolution),
           let val = VideoExportSettings.Resolution(rawValue: raw) {
            exportSettings.resolution = val
        }
        if let raw = d.string(forKey: SettingsKey.frameRate),
           let val = VideoExportSettings.FrameRate(rawValue: raw) {
            exportSettings.frameRate = val
        }
        if let raw = d.string(forKey: SettingsKey.codec),
           let val = VideoExportSettings.Codec(rawValue: raw) {
            exportSettings.codec = val
        }
        if let raw = d.string(forKey: SettingsKey.container),
           let val = VideoExportSettings.ContainerFormat(rawValue: raw) {
            exportSettings.containerFormat = val
        }
        if d.object(forKey: SettingsKey.bitrate) != nil {
            exportSettings.bitrate = d.integer(forKey: SettingsKey.bitrate)
        }
        if let raw = d.string(forKey: SettingsKey.encodingMode),
           let val = VideoExportSettings.EncodingMode(rawValue: raw) {
            exportSettings.encodingMode = val
        }

        // Crop
        if d.object(forKey: SettingsKey.cropMode) != nil,
           let val = CustomVideoCompositionInstruction.LetterboxMode(rawValue: d.integer(forKey: SettingsKey.cropMode)) {
            letterboxMode = val
        }
        if d.object(forKey: SettingsKey.cropPositionX) != nil {
            cropPositionX = d.double(forKey: SettingsKey.cropPositionX)
        }

        // Smart Framing
        if d.object(forKey: SettingsKey.smartFraming) != nil {
            smartFramingEnabled = d.bool(forKey: SettingsKey.smartFraming)
        }
        if let raw = d.string(forKey: SettingsKey.smartFramingSmoothness),
           let val = SmartFramingSettings.Smoothness(rawValue: raw) {
            smartFramingSmoothness = val
        }

        // HDR
        if d.object(forKey: SettingsKey.hdrConversion) != nil {
            hdrConversionEnabled = d.bool(forKey: SettingsKey.hdrConversion)
        }
        if d.object(forKey: SettingsKey.toneMappingMode) != nil,
           let val = CustomVideoCompositionInstruction.ToneMappingMode(rawValue: d.integer(forKey: SettingsKey.toneMappingMode)) {
            toneMappingMode = val
        }

        // Output directory (Security-Scoped Bookmark)
        restoreOutputDirectoryBookmark()
    }

    private func saveSettings() {
        guard !isRestoringSettings else { return }
        let d = UserDefaults.standard
        d.set(exportSettings.resolution.rawValue, forKey: SettingsKey.resolution)
        d.set(exportSettings.frameRate.rawValue, forKey: SettingsKey.frameRate)
        d.set(exportSettings.codec.rawValue, forKey: SettingsKey.codec)
        d.set(exportSettings.containerFormat.rawValue, forKey: SettingsKey.container)
        d.set(exportSettings.bitrate, forKey: SettingsKey.bitrate)
        d.set(exportSettings.encodingMode.rawValue, forKey: SettingsKey.encodingMode)
        d.set(letterboxMode.rawValue, forKey: SettingsKey.cropMode)
        d.set(cropPositionX, forKey: SettingsKey.cropPositionX)
        d.set(smartFramingEnabled, forKey: SettingsKey.smartFraming)
        d.set(smartFramingSmoothness.rawValue, forKey: SettingsKey.smartFramingSmoothness)
        d.set(hdrConversionEnabled, forKey: SettingsKey.hdrConversion)
        d.set(toneMappingMode.rawValue, forKey: SettingsKey.toneMappingMode)
    }

    private func saveOutputDirectoryBookmark() {
        guard !isRestoringSettings else { return }
        let d = UserDefaults.standard
        guard let url = outputDirectoryURL else {
            d.removeObject(forKey: SettingsKey.outputDirBookmark)
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            d.set(bookmark, forKey: SettingsKey.outputDirBookmark)
        } catch {
            NSLog("ContentViewModel: failed to create bookmark for output dir: %@", error.localizedDescription)
        }
    }

    private func restoreOutputDirectoryBookmark() {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.outputDirBookmark) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                outputDirectoryURL = url
                // Re-save if bookmark was stale
                if isStale {
                    saveOutputDirectoryBookmark()
                }
            }
        } catch {
            NSLog("ContentViewModel: failed to restore output dir bookmark: %@", error.localizedDescription)
            UserDefaults.standard.removeObject(forKey: SettingsKey.outputDirBookmark)
        }
    }

    // MARK: - ファイル選択パネル

    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true   // 複数選択対応
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            self.selectedVideoURLs = panel.urls
            self.hasConverted = false
        }
    }

    /// 出力先ディレクトリをユーザーに選択させる（サンドボックス環境で書き込み権限を取得するため）
    func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        panel.message = "Choose a folder to save converted videos"

        // 入力ファイルの親ディレクトリをデフォルトに
        if let firstInput = selectedVideoURLs.first {
            panel.directoryURL = firstInput.deletingLastPathComponent()
        }

        if panel.runModal() == .OK, let url = panel.url {
            self.outputDirectoryURL = url
        }
    }

    // MARK: - D&D（複数ファイル対応）

    func handleDrop(providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }

        let total = providers.count
        let lock = DispatchQueue(label: "drop.url.lock")
        var completedCount = 0
        var loadedURLs: [URL] = []

        func finalize() {
            // lock キューで呼ぶこと
            completedCount += 1
            if completedCount == total {
                let urls = loadedURLs
                DispatchQueue.main.async {
                    if !urls.isEmpty {
                        self.selectedVideoURLs = urls
                        self.hasConverted = false
                    }
                }
            }
        }

        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { (obj, _) in
                    lock.async {
                        if let nsurl = obj as? NSURL { loadedURLs.append(nsurl as URL) }
                        finalize()
                    }
                }
            } else {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { (tempURL, _) in
                    if let temp = tempURL {
                        lock.async {
                            loadedURLs.append(temp)
                            finalize()
                        }
                    } else {
                        // フォールバック: loadItem で再試行
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, _) in
                            lock.async {
                                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                    loadedURLs.append(url)
                                } else if let url = item as? URL {
                                    loadedURLs.append(url)
                                } else if let nsurl = item as? NSURL {
                                    loadedURLs.append(nsurl as URL)
                                }
                                finalize()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - サムネイル生成

    /// 現在の thumbnailTime でサムネイルを再生成（プレビューの「Seek」ボタン用）
    func generateThumbnailAtCurrentTime() {
        generateThumbnail()
    }

    private func generateThumbnail() {
        thumbnail = nil
        guard let url = selectedVideoURLs.first else { return }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)

        let seekTime = CMTime(seconds: thumbnailTime, preferredTimescale: 600)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var actual = CMTime.zero
                let cgImage = try generator.copyCGImage(at: seekTime, actualTime: &actual)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async { self.thumbnail = nsImage }
            } catch {
                // フォールバック: 先頭フレームを取得
                do {
                    var actual = CMTime.zero
                    let cgImage = try generator.copyCGImage(at: .zero, actualTime: &actual)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    DispatchQueue.main.async { self.thumbnail = nsImage }
                } catch {
                    // サムネイル取得不可
                }
            }
        }
    }

    // MARK: - 動画デュレーション読み込み

    private func loadVideoDuration() {
        videoDuration = 0.0
        guard let url = selectedVideoURLs.first else { return }
        Task {
            let asset = AVAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let secs = duration.seconds
                self.videoDuration = (secs.isNaN || secs.isInfinite) ? 0.0 : max(secs, 0.0)
            } catch {
                self.videoDuration = 0.0
            }
        }
    }

    // MARK: - キャンセル

    func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
    }

    // MARK: - 変換（バッチ対応）

    func convertVideo() {
        guard !selectedVideoURLs.isEmpty else { return }

        // 出力先ディレクトリが未選択なら選択パネルを表示
        if outputDirectoryURL == nil {
            selectOutputDirectory()
            guard outputDirectoryURL != nil else { return }
        }

        self.hasConverted = false
        isProcessing = true
        hasError = false
        statusMessage = "Starting conversion..."
        progress = 0.0
        DockProgress.start()

        let urlsToProcess = selectedVideoURLs
        let capturedExportSettings = exportSettings
        let smartSettings = SmartFramingSettings(enabled: smartFramingEnabled, smoothness: smartFramingSmoothness)
        let lboxMode = letterboxMode
        let capturedCropPositionX = CGFloat(cropPositionX)
        let capturedCropPositionY = CGFloat(cropPositionY)
        let hdrEnabled = hdrConversionEnabled
        let toneMode = toneMappingMode
        let total = urlsToProcess.count

        // サンドボックス環境では出力ディレクトリのセキュリティスコープを取得
        let outputDir = self.outputDirectoryURL
        let isAccessingOutputDir = outputDir?.startAccessingSecurityScopedResource() ?? false

        conversionTask = Task {
            defer { if isAccessingOutputDir, let dir = outputDir { dir.stopAccessingSecurityScopedResource() } }
            var completedCount = 0
            var lastOutputURL: URL? = nil

            for (index, inputURL) in urlsToProcess.enumerated() {
                if Task.isCancelled { break }

                let filePrefix = total > 1 ? "[\(index + 1)/\(total)] " : ""
                let isAccessing = inputURL.startAccessingSecurityScopedResource()
                defer { if isAccessing { inputURL.stopAccessingSecurityScopedResource() } }

                let outExt = capturedExportSettings.resolvedFileExtension
                let inputFilename = inputURL.deletingPathExtension().lastPathComponent
                let baseDir = outputDir ?? inputURL.deletingLastPathComponent()
                let outputURL = baseDir
                    .appendingPathComponent("\(inputFilename)_vertical")
                    .appendingPathExtension(outExt)

                // ファイルごとの進捗基準値をキャプチャ（クロージャが後から参照しても正しい値を使うため）
                let countBeforeFile = completedCount

                do {
                    try await videoProcessor.convertToVertical(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        exportSettings: capturedExportSettings,
                        smartFramingSettings: smartSettings,
                        letterboxMode: lboxMode,
                        cropPositionX: capturedCropPositionX,
                        cropPositionY: capturedCropPositionY,
                        hdrConversionEnabled: hdrEnabled,
                        toneMappingMode: toneMode,
                        progressHandler: { prog, label in
                            Task { @MainActor in
                                let overall = (Double(countBeforeFile) + prog) / Double(total)
                                self.progress = overall
                                self.phaseLabel = "\(filePrefix)\(label)"
                                DockProgress.update(overall)
                            }
                        }
                    )
                    completedCount += 1
                    lastOutputURL = outputURL

                    // デモ版: エンコード成功をカウント
                    if BuildEdition.current == .demo {
                        #if EDITION_DEMO
                        DemoUsageTracker.shared.recordEncode()
                        #endif
                    }

                    if total == 1 {
                        self.statusMessage = "Conversion complete!\nSaved to: \(outputURL.path)"
                        self.hasConverted = true
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        NSSound(named: .init("Glass"))?.play()
                    } else {
                        self.statusMessage = "[\(completedCount)/\(total)] Converted: \(inputURL.lastPathComponent)"
                        self.progress = Double(completedCount) / Double(total)
                        DockProgress.update(self.progress)
                    }
                } catch VideoProcessorError.cancelled {
                    self.statusMessage = "Conversion cancelled"
                    self.hasError = false
                    self.hasConverted = false
                    break
                } catch {
                    self.statusMessage = "\(filePrefix)Error: \(error.localizedDescription)"
                    self.hasError = true
                    // バッチモードでは次のファイルへ続行（単体は停止）
                    if total == 1 { break }
                }
            }

            // バッチ完了サマリー
            if total > 1, completedCount > 0, !Task.isCancelled {
                let failed = total - completedCount
                let failSuffix = failed > 0 ? " (\(failed) failed)" : ""
                self.statusMessage = "Batch complete: \(completedCount)/\(total) files converted\(failSuffix)"
                self.hasConverted = (completedCount == total)
                if let lastURL = lastOutputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([lastURL])
                }
                NSSound(named: .init("Glass"))?.play()
            }

            self.phaseLabel = ""
            self.isProcessing = false
            DockProgress.stop()
        }
    }
}
