//
//  ContentView.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            // Liquid Glass が映える鮮やかなグラデーション背景
            LinearGradient(
                colors: [
                    Color(hue: 0.62, saturation: 0.80, brightness: 0.60),
                    Color(hue: 0.78, saturation: 0.90, brightness: 0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                // ヘッダー
                VStack(spacing: 4) {
                    Text("Vertical Converter")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("16:9 → 9:16 変換")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 22)

                dropZone
                settingsPanel
                smartFramingPanel
                hdrPanel
                actionPanel

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 500, height: 690)
    }

    // MARK: - ドロップゾーン

    private var dropZone: some View {
        ZStack {
            if let videoURL = viewModel.selectedVideoURL {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                    Text(videoURL.lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button("別のファイルを選択") {
                        viewModel.selectedVideoURL = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .underline()
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: isTargeted)
                    Text("ドラッグ＆ドロップ")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("または")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Button("ファイルを選択") {
                        viewModel.selectFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
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
                    isTargeted ? Color.white.opacity(0.9) : Color.white.opacity(0.25),
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
    }

    // MARK: - 出力設定パネル

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            settingRow(label: "解像度", icon: "aspectratio") {
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
            settingRow(label: "ビットレート", icon: "waveform") {
                SlidingPicker(
                    labels: [8, 10, 12].map { "\($0) Mbps" },
                    values: [8, 10, 12],
                    selection: $viewModel.exportSettings.bitrate
                )
            }
            panelDivider
            settingRow(label: "品質モード", icon: "slider.horizontal.3") {
                SlidingPicker(
                    labels: VideoExportSettings.EncodingMode.allCases.map { $0.rawValue },
                    values: VideoExportSettings.EncodingMode.allCases,
                    selection: $viewModel.exportSettings.encodingMode
                )
            }
            panelDivider
            settingRow(label: "レターボックス", icon: "crop") {
                SlidingPicker(
                    labels: CustomVideoCompositionInstruction.LetterboxMode.allCases.map { $0.displayName },
                    values: CustomVideoCompositionInstruction.LetterboxMode.allCases,
                    selection: $viewModel.letterboxMode
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26+→.glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - スマートフレーミングパネル（常に固定高さ）

    private var smartFramingPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("スマートフレーミング", systemImage: "person.crop.rectangle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: $viewModel.smartFramingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            panelDivider
            // パン速度: 常に表示。OFFのときはグレーアウト（高さ変化なし）
            settingRow(label: "パン速度", icon: "arrow.left.and.right") {
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26+→.glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - HDR -> SDR パネル

    private var hdrPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HDR→SDR 変換", systemImage: "sun.max.trianglebadge.exclamation")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: $viewModel.hdrConversionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            panelDivider
            settingRow(label: "ターゲット色空間", icon: "paintpalette") {
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - アクションパネル

    private var actionPanel: some View {
        VStack(spacing: 10) {
            if viewModel.isProcessing {
                Button {
                    viewModel.cancelConversion()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("変換を中止")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.65))
            } else {
                Button {
                    viewModel.convertVideo()
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("変換開始")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hue: 0.38, saturation: 0.75, brightness: 0.72))
                .disabled(viewModel.selectedVideoURL == nil)
            }

            // プログレス（固定高さ）
            VStack(spacing: 5) {
                if viewModel.isProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text(viewModel.phaseLabel)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f%%", viewModel.progress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    ProgressView(value: viewModel.progress)
                        .tint(.white)
                }
            }
            .frame(height: 40)

            Text(viewModel.statusMessage.isEmpty ? " " : viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(viewModel.hasError ? Color.red : Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(height: 32)
                .lineLimit(2)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // TODO: Xcode 26 以降は下記に差し替え
        // .glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Panel Helpers

    private var panelDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.18))
            .padding(.vertical, 6)
    }

    private func settingRow<Content: View>(
        label: String, icon: String,
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
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
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { i in
                let isSelected = selection == values[i]
                Button {
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.28))
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var exportSettings = VideoExportSettings()
    @Published var smartFramingEnabled: Bool = false
    @Published var smartFramingSmoothness: SmartFramingSettings.Smoothness = .normal
    @Published var letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
    @Published var hdrConversionEnabled: Bool = false
    @Published var hdrTarget: CustomVideoCompositionInstruction.HDRTarget = .sRGB
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var phaseLabel: String = "変換中..."
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
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (urlData, error) in
            DispatchQueue.main.async {
                if let urlData = urlData as? Data,
                   let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                    self.selectedVideoURL = url
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
        
        isProcessing = true
        hasError = false
        statusMessage = "変換を開始しています..."
        progress = 0.0
        DockProgress.start()

        // 出力ファイル名を生成
        let inputFilename = inputURL.deletingPathExtension().lastPathComponent
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(inputFilename)_vertical.mp4")
        
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
                
                self.statusMessage = "変換完了！\n保存先: \(outputURL.path)"
                self.hasError = false
                
                // 保存先をFinderで表示
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch VideoProcessorError.cancelled {
                self.statusMessage = "変換を中止しました"
                self.hasError = false
            } catch {
                self.statusMessage = "エラー: \(error.localizedDescription)"
                self.hasError = true
            }
            
            self.isProcessing = false
            DockProgress.stop()
        }
    }
}
