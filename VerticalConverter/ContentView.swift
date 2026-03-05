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

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isTargeted = false
    @State private var showingCropPreview: Bool = false

    var body: some View {
        ZStack {
            // Liquid Glass が映える鮮やかなグラデーション背景
            Color(nsColor: NSColor.windowBackgroundColor)
            .ignoresSafeArea()

            VStack(spacing: 12) {
                // ヘッダー
                VStack(spacing: 4) {
                    Text("Vertical Converter")
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                    Text("Convert 16:9 → 9:16")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
                .padding(.top, 22)

                dropZone
                    .frame(maxWidth: .infinity)
                settingsPanel
                    .frame(maxWidth: .infinity)
                smartFramingPanel
                    .frame(maxWidth: .infinity)
                hdrPanel
                    .frame(maxWidth: .infinity)
                actionPanel
                    .frame(maxWidth: .infinity)

                // Spacer removed to avoid large empty area below panels
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 900)
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
                        selection: $viewModel.letterboxMode
                    )

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
                        .symbolEffect(.pulse, isActive: isTargeted)
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
                        .symbolEffect(.pulse, isActive: isTargeted)
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
                CropPreviewView(thumbnail: viewModel.thumbnail, selection: $viewModel.letterboxMode)
            }
        }
    }

    // MARK: - Output Settings Panel

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            settingRow(label: "Resolution", icon: "aspectratio") {
                SlidingPicker(
                    labels: VideoExportSettings.Resolution.allCases.map { $0.rawValue },
                    values: VideoExportSettings.Resolution.allCases,
                    selection: $viewModel.exportSettings.resolution
                )
            }
            panelDivider
            settingRow(label: "FPS", icon: "film.stack") {
                SlidingPicker(
                    labels: VideoExportSettings.FrameRate.allCases.map { $0.displayLabel },
                    values: VideoExportSettings.FrameRate.allCases,
                    selection: $viewModel.exportSettings.frameRate
                )
            }
            panelDivider
            settingRow(label: "Codec", icon: "cpu") {
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
            settingRow(label: "Bitrate", icon: "dial.min.fill") {
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
            settingRow(label: "Bitrate Mode", icon: "slider.horizontal.3") {
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
            settingRow(label: "Crop", icon: "crop") {
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
            settingRow(label: "Follow Speed", icon: "arrow.left.and.right") {
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

    private var hdrPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HDR→SDR Conversion", systemImage: "display")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $viewModel.hdrConversionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            panelDivider
            settingRow(label: "Tone Map", icon: "camera.filters") {
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
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
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
                                .onChange(of: geo.size.width) { itemWidth = $0 }
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
            CropPreviewThumbnail(image: thumbnail, mode: mode, isSelected: selection == mode)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CropPreviewThumbnail: View {
    let image: NSImage?
    let mode: CustomVideoCompositionInstruction.LetterboxMode
    let isSelected: Bool

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
                        croppedImage(img: img, canvasSize: canvasSize, mode: mode)
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
    
    private func croppedImage(img: NSImage, canvasSize: CGSize, mode: CustomVideoCompositionInstruction.LetterboxMode) -> some View {
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

            return Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: canvasSize.width, height: scaledHeight)
                .clipped()
                .position(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        } else if mode == .fitHeight {
            // Fit the source height to the canvas height (left/right crop).
            let scale = canvasSize.height / img.size.height
            let scaledWidth = img.size.width * scale

            return Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: scaledWidth, height: canvasSize.height)
                .clipped()
                .position(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        } else {
            // For crop modes: create an image sized to canvas width and height matching targetAspect,
            // then center it so it appears as the sharp crop area.
            let croppedHeight = canvasSize.width / targetAspect

            return Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: canvasSize.width, height: croppedHeight)
                .clipped()
                .position(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        }
    }
}

@MainActor
class ContentViewModel: ObservableObject {

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
    @Published var exportSettings = VideoExportSettings()
    @Published var hasConverted: Bool = false
    @Published var smartFramingEnabled: Bool = false
    @Published var smartFramingSmoothness: SmartFramingSettings.Smoothness = .normal
    @Published var letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
    @Published var hdrConversionEnabled: Bool = false
    @Published var toneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var phaseLabel: String = ""
    @Published var statusMessage: String = ""
    @Published var hasError: Bool = false

    private let videoProcessor = VideoProcessor()
    private var conversionTask: Task<Void, Never>?

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
        let hdrEnabled = hdrConversionEnabled
        let toneMode = toneMappingMode
        let total = urlsToProcess.count

        conversionTask = Task {
            var completedCount = 0
            var lastOutputURL: URL? = nil

            for (index, inputURL) in urlsToProcess.enumerated() {
                if Task.isCancelled { break }

                let filePrefix = total > 1 ? "[\(index + 1)/\(total)] " : ""
                let isAccessing = inputURL.startAccessingSecurityScopedResource()
                defer { if isAccessing { inputURL.stopAccessingSecurityScopedResource() } }

                let outExt = (capturedExportSettings.codec == .prores422VT) ? "mov" : "mp4"
                let inputFilename = inputURL.deletingPathExtension().lastPathComponent
                let outputURL = inputURL.deletingLastPathComponent()
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

                    if total == 1 {
                        self.statusMessage = "Conversion complete!\nSaved to: \(outputURL.path)"
                        self.hasConverted = true
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
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
            }

            self.phaseLabel = ""
            self.isProcessing = false
            DockProgress.stop()
        }
    }
}
