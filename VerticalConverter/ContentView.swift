//
//  ContentView.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Vertical Video Converter")
                .font(.title)
                .padding(.top, 30)
            
            Text("16:9の動画を縦型（9:16）に変換します")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // ドロップゾーン
            VStack {
                if let videoURL = viewModel.selectedVideoURL {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        
                        Text(videoURL.lastPathComponent)
                            .font(.headline)
                        
                        Button("別のファイルを選択") {
                            viewModel.selectedVideoURL = nil
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    VStack(spacing: 15) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("動画ファイルをドラッグ&ドロップ")
                            .font(.headline)
                        
                        Text("または")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("ファイルを選択") {
                            viewModel.selectFile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(width: 400, height: 200)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                            .foregroundColor(.blue.opacity(0.5))
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                viewModel.handleDrop(providers: providers)
                return true
            }
            
            // ビットレート選択
            HStack(spacing: 15) {
                Text("ビットレート:")
                    .font(.body)
                
                Picker("", selection: $viewModel.selectedBitrate) {
                    Text("8 Mbps").tag(8)
                    Text("10 Mbps").tag(10)
                    Text("12 Mbps").tag(12)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
            
            // 変換ボタン
            Button(action: {
                viewModel.convertVideo()
            }) {
                HStack {
                    if viewModel.isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(viewModel.isProcessing ? "変換中..." : "変換開始")
                }
                .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedVideoURL == nil || viewModel.isProcessing)
            .padding(.vertical, 10)
            
            // プログレスバー
            if viewModel.isProcessing {
                VStack(spacing: 5) {
                    ProgressView(value: viewModel.progress)
                        .frame(width: 300)
                    Text(String(format: "%.0f%%", viewModel.progress * 100))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // ステータスメッセージ
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(viewModel.hasError ? .red : .green)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(width: 500, height: 500)
        .padding()
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var selectedBitrate: Int = 10
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var hasError: Bool = false
    
    private let videoProcessor = VideoProcessor()
    
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
    
    func convertVideo() {
        guard let inputURL = selectedVideoURL else { return }
        
        isProcessing = true
        hasError = false
        statusMessage = "変換を開始しています..."
        progress = 0.0
        
        // 出力ファイル名を生成
        let inputFilename = inputURL.deletingPathExtension().lastPathComponent
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(inputFilename)_vertical.mp4")
        
        Task {
            do {
                // セキュリティスコープ付きリソースへのアクセスを開始
                let isAccessingSecurityScope = inputURL.startAccessingSecurityScopedResource()
                defer {
                    if isAccessingSecurityScope {
                        inputURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                try await videoProcessor.convertToVertical(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    bitrate: selectedBitrate,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.progress = progress
                        }
                    }
                )
                
                self.statusMessage = "変換完了！\n保存先: \(outputURL.path)"
                self.hasError = false
                
                // 保存先をFinderで表示
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch {
                self.statusMessage = "エラー: \(error.localizedDescription)"
                self.hasError = true
            }
            
            self.isProcessing = false
        }
    }
}
