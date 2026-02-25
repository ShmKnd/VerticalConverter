//
//  ContentView.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

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
        .overlay {
            if showingCropPreview {
                GeometryReader { geo in
                    let panelWidth = min(geo.size.width * 0.9, 720)
                    let panelHeight = min(geo.size.height * 0.82, 780)
                    // Remove scrolling: expand vertically so all content is visible
                    let extraVertical: CGFloat = 160.0

                    VStack {
                        HStack {
                            Spacer()
                            ZStack(alignment: .topTrailing) {
                                // Panel background + clipping
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.ultraThinMaterial)
                                    .frame(width: panelWidth, height: panelHeight + extraVertical)
                                    .shadow(radius: 24)

                                // Non-scrollable content (show everything; panel is taller)
                                VStack(spacing: 12) {
                                    CropPreviewView(thumbnail: viewModel.thumbnail, selection: $viewModel.letterboxMode)
                                }
                                // reduce top padding so label and close button align tighter
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                                .frame(width: panelWidth - 2, height: panelHeight - 2 + extraVertical)
                                .clipShape(RoundedRectangle(cornerRadius: 20))

                                Button(action: { showingCropPreview = false }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.primary.opacity(0.9))
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                                // move close button down to match the panel title baseline
                                .padding(.top, 20)
                                .padding(.trailing, 16)
                            }
                            Spacer()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.opacity.combined(with: .scale))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showingCropPreview)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            // UX: When dragging over the drop zone, always show the drop prompt
            // so users get clear feedback even if a file was previously loaded.
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
                            viewModel.selectedVideoURL = nil
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
                            viewModel.selectedVideoURL = nil
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
                        dash: viewModel.selectedVideoURL == nil ? [8, 4] : []
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
            .disabled(viewModel.selectedVideoURL == nil)
            .opacity(viewModel.selectedVideoURL == nil ? 0.45 : 1.0)
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
            settingRow(label: "FPS", icon: "camera.aperture") {
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
            settingRow(label: "Bitrate", icon: "waveform") {
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
                Label("HDR→SDR Conversion", systemImage: "sun.max.trianglebadge.exclamation")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $viewModel.hdrConversionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            panelDivider
            settingRow(label: "Target", icon: "paintpalette") {
                SlidingPicker(
                    labels: ["sRGB", "Rec.709"],
                    values: [CustomVideoCompositionInstruction.HDRTarget.sRGB, CustomVideoCompositionInstruction.HDRTarget.rec709],
                    selection: $viewModel.hdrTarget
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
                        Text("Start Conversion")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hue: 0.38, saturation: 0.75, brightness: 0.72))
                .disabled(viewModel.selectedVideoURL == nil)
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
                Label(label, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 115, alignment: .leading)
            picker()
        }
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

    private let modes = CustomVideoCompositionInstruction.LetterboxMode.allCases
    private let gridColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Crop Preview", systemImage: "crop")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(modes, id: \.self) { mode in
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
        }
        // ensure top inset matches the close button so the title and xmark align
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            case .fitWidth: return outputAspect
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
    @Published var selectedVideoURL: URL? {
        didSet {
            if let _ = selectedVideoURL {
                self.hasConverted = false
                generateThumbnail()
            } else {
                self.thumbnail = nil
            }
        }
    }
    @Published var thumbnail: NSImage? = nil
    @Published var exportSettings = VideoExportSettings()
    @Published var hasConverted: Bool = false
    @Published var smartFramingEnabled: Bool = false
    @Published var smartFramingSmoothness: SmartFramingSettings.Smoothness = .normal
    @Published var letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
    @Published var hdrConversionEnabled: Bool = false
    @Published var hdrTarget: CustomVideoCompositionInstruction.HDRTarget = .sRGB
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var phaseLabel: String = ""
    @Published var statusMessage: String = ""
    @Published var hasError: Bool = false
    
    private let videoProcessor = VideoProcessor()
    private var conversionTask: Task<Void, Never>?
    
    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        
        if panel.runModal() == .OK {
            self.selectedVideoURL = panel.url
            self.hasConverted = false
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        

        // 1) Preferred modern API: try loading a URL/NSURL object directly
        if provider.canLoadObject(ofClass: NSURL.self) {
            provider.loadObject(ofClass: NSURL.self) { (obj, error) in
                DispatchQueue.main.async {
                    if let nsurl = obj as? NSURL {
                        self.selectedVideoURL = nsurl as URL
                        self.hasConverted = false
                        return
                    }
                    // If that didn't work, continue to fallback attempts
                    self.attemptFileLoadFallback(provider: provider)
                }
            }
            return
        }

        // Otherwise, try fallbacks
        attemptFileLoadFallback(provider: provider)
    }

    private func attemptFileLoadFallback(provider: NSItemProvider) {
        // 2) Try loadFileRepresentation for a temp local URL
        provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { (tempURL, error) in
            if let temp = tempURL {
                DispatchQueue.main.async {
                    self.selectedVideoURL = temp
                    self.hasConverted = false
                }
                return
            }

            // 3) Last-resort: loadItem and handle multiple possible return types
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                DispatchQueue.main.async {
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        self.selectedVideoURL = url
                        self.hasConverted = false
                    } else if let url = item as? URL {
                        self.selectedVideoURL = url
                        self.hasConverted = false
                    } else if let nsurl = item as? NSURL {
                        self.selectedVideoURL = nsurl as URL
                        self.hasConverted = false
                    } else if let str = item as? String, let url = URL(string: str) {
                        self.selectedVideoURL = url
                        self.hasConverted = false
                    } else {
                    }
                }
            }
        }
    }

    private func generateThumbnail() {
        thumbnail = nil
        guard let url = selectedVideoURL else { return }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // reasonable max size for thumbnails
        generator.maximumSize = CGSize(width: 960, height: 960)

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var actual = CMTime.zero
                let cgImage = try generator.copyCGImage(at: time, actualTime: &actual)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async {
                    self.thumbnail = nsImage
                }
            } catch {
                // fallback to time zero
                do {
                    var actual = CMTime.zero
                    let cgImage = try generator.copyCGImage(at: CMTime.zero, actualTime: &actual)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    DispatchQueue.main.async {
                        self.thumbnail = nsImage
                    }
                } catch {
                    // could not generate thumbnail
                }
            }
        }
    }
    
    func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
    }

    func convertVideo() {
        guard let inputURL = selectedVideoURL else { return }

        // Mark conversion as not-yet-completed at start
        self.hasConverted = false

        isProcessing = true
        hasError = false
        statusMessage = "Starting conversion..."
        progress = 0.0
        DockProgress.start()

        // 出力ファイル名を生成（ProRes は .mov）
        let inputFilename = inputURL.deletingPathExtension().lastPathComponent
        let outExt = (exportSettings.codec == .prores422VT) ? "mov" : "mp4"
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(inputFilename)_vertical")
            .appendingPathExtension(outExt)

        conversionTask = Task {
            do {
                // セキュリティスコープ付きリソースへのアクセスを開始
                let isAccessingSecurityScope = inputURL.startAccessingSecurityScopedResource()
                defer {
                    if isAccessingSecurityScope {
                        inputURL.stopAccessingSecurityScopedResource()
                    }
                }

                // スマートフレーミング設定を作成
                let settings = SmartFramingSettings(
                    enabled: smartFramingEnabled,
                    smoothness: smartFramingSmoothness
                )

                try await videoProcessor.convertToVertical(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    exportSettings: exportSettings,
                    smartFramingSettings: settings,
                    letterboxMode: letterboxMode,
                    hdrConversionEnabled: hdrConversionEnabled,
                    hdrTarget: hdrTarget,
                    progressHandler: { progress, label in
                        Task { @MainActor in
                            self.progress = progress
                            self.phaseLabel = label
                            DockProgress.update(progress)
                        }
                    }
                )

                self.statusMessage = "Conversion complete!\nSaved to: \(outputURL.path)"
                self.hasError = false

                // Mark successful conversion
                self.hasConverted = true

                // 保存先をFinderで表示
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch VideoProcessorError.cancelled {
                self.statusMessage = "Conversion cancelled"
                self.hasError = false
                self.hasConverted = false
            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.hasError = true
                self.hasConverted = false
            }

            // Clear the transient phase label so "Converting..." doesn't remain visible
            self.phaseLabel = ""
            self.isProcessing = false
            DockProgress.stop()
        }
    }
}
