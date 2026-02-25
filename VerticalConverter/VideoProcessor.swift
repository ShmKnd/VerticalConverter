//
//  VideoProcessor.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import Foundation
import AVFoundation
import CoreImage
import VideoToolbox
import CoreMedia

enum VideoProcessorError: LocalizedError {
    case invalidInput
    case compositionFailed
    case exportFailed
    case unsupportedFormat
    
    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "入力動画が無効です"
        case .compositionFailed:
            return "動画の合成に失敗しました"
        case .exportFailed:
            return "動画の書き出しに失敗しました"
        case .unsupportedFormat:
            return "サポートされていない動画形式です"
        }
    }
}

actor VideoProcessor {
    func convertToVertical(
        inputURL: URL,
        outputURL: URL,
        bitrate: Int,
        smartFramingSettings: SmartFramingSettings,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        // 既存の出力ファイルを削除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let asset = AVAsset(url: inputURL)
        
        // 動画トラックを取得
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessorError.invalidInput
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        
        // トランスフォームを適用してサイズを調整
        let videoSize = naturalSize.applying(preferredTransform)
        let width = abs(videoSize.width)
        let height = abs(videoSize.height)
        
        // 出力サイズを計算（9:16の縦型）
        let outputWidth: CGFloat = 1080
        let outputHeight: CGFloat = 1920
        
        // コンポジションを作成
        let (composition, videoComposition) = try await createComposition(
            asset: asset,
            videoTrack: videoTrack,
            inputSize: CGSize(width: width, height: height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            smartFramingSettings: smartFramingSettings
        )
        
        // エクスポート
        try await exportVideo(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL,
            bitrate: bitrate,
            progressHandler: progressHandler
        )
    }
    
    private func createComposition(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        inputSize: CGSize,
        outputSize: CGSize,
        smartFramingSettings: SmartFramingSettings
    ) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let composition = AVMutableComposition()
        
        // コンポジションにトラックを追加
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoProcessorError.compositionFailed
        }
        
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        
        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        
        // オーディオトラックを追加
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoProcessorError.compositionFailed
            }
            
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }
        
        // ビデオコンポジションを作成
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        // カスタムコンポジターを使用
        videoComposition.customVideoCompositorClass = VerticalVideoCompositor.self
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        
        // トランスフォームを計算
        let transform = calculateTransform(
            inputSize: inputSize,
            outputSize: outputSize
        )
        layerInstruction.setTransform(transform, at: .zero)
        
        // カスタムインストラクションを作成
        let instruction = CustomVideoCompositionInstruction(
            timeRange: timeRange,
            layerInstructions: [layerInstruction],
            smartFramingEnabled: smartFramingSettings.enabled,
            dampingFactor: smartFramingSettings.smoothness.dampingFactor,
            inputSize: inputSize
        )
        
        videoComposition.instructions = [instruction]
        
        return (composition, videoComposition)
    }
    
    private func calculateTransform(
        inputSize: CGSize,
        outputSize: CGSize
    ) -> CGAffineTransform {
        // 16:9の動画を9:16に配置する際のスケール（横幅を基準に）
        let scale = outputSize.width / inputSize.width
        
        // スケール後のサイズ
        let scaledWidth = inputSize.width * scale
        let scaledHeight = inputSize.height * scale
        
        // 中央に配置するためのオフセット
        let offsetX = (outputSize.width - scaledWidth) / 2
        let offsetY = (outputSize.height - scaledHeight) / 2
        
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }
    
    private func exportVideo(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        outputURL: URL,
        bitrate: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw VideoProcessorError.exportFailed
        }
        
        export.outputURL = outputURL
        export.outputFileType = AVFileType.mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        
        // 注: AVAssetExportSessionではプリセット名でビットレートが決定されます
        // カスタムビットレートを設定する場合は、AVAssetWriterを使用する必要があります
        
        // プログレス監視用タスク
        let progressTask = Task {
            while !Task.isCancelled {
                let progress = Double(export.progress)
                await MainActor.run {
                    progressHandler(progress)
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            }
        }
        
        await export.export()
        progressTask.cancel()
        
        await MainActor.run {
            progressHandler(1.0)
        }
        
        switch export.status {
        case .completed:
            return
        case .failed:
            throw export.error ?? VideoProcessorError.exportFailed
        case .cancelled:
            throw VideoProcessorError.exportFailed
        default:
            throw VideoProcessorError.exportFailed
        }
    }
}
