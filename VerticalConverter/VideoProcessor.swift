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
    case cancelled
    
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
        case .cancelled:
            return "変換がキャンセルされました"
        }
    }
}

actor VideoProcessor {
    /// Check whether a hardware VT encoder is available for the requested codec variant.
    static func isHardwareEncoderAvailable(for codec: VideoExportSettings.Codec) -> Bool {
        switch codec {
        case .h264VT:
            return isHardwareEncoderAvailable(codecType: kCMVideoCodecType_H264)
        case .h265VT:
            return isHardwareEncoderAvailable(codecType: kCMVideoCodecType_HEVC)
        case .prores422VT:
            // Try to discover a ProRes-capable encoder via VTCopyVideoEncoderList
            var cfArray: CFArray?
            let status = VTCopyVideoEncoderList(nil, &cfArray)
            if status == noErr, let arr = cfArray as? [[String: Any]] {
                for dict in arr {
                    if let name = dict[kVTVideoEncoderList_EncoderName as String] as? String {
                        if name.lowercased().contains("prores") {
                            // If a ProRes encoder exists, prefer it as hardware-capable
                            return true
                        }
                    }
                }
            }
            return false
        default:
            return false
        }
    }

    private static func isHardwareEncoderAvailable(codecType: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let spec: CFDictionary = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: 16,
                                                height: 16,
                                                codecType: codecType,
                                                encoderSpecification: spec,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &session)
        if status == noErr, let s = session {
            VTCompressionSessionInvalidate(s)
            return true
        }
        return false
    }
    func convertToVertical(
        inputURL: URL,
        outputURL: URL,
        exportSettings: VideoExportSettings = VideoExportSettings(),
        smartFramingSettings: SmartFramingSettings,
        letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth,
        hdrConversionEnabled: Bool = false,
        hdrTarget: CustomVideoCompositionInstruction.HDRTarget = .sRGB,
        progressHandler: @escaping (Double, String) -> Void  // (progress, phaseLabel)
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
        let (resW, resH) = exportSettings.resolution.outputSize
        let outputWidth: CGFloat  = CGFloat(resW)
        let outputHeight: CGFloat = CGFloat(resH)
        
        // ── スマートフレーミング ONなら事前解析（第1パス）──
        var precomputedOffsets: [CGPoint]? = nil
        if smartFramingSettings.enabled {
            let analyzer = SmartFramingAnalyzer()
            precomputedOffsets = try await analyzer.analyze(
                asset: asset,
                videoTrack: videoTrack,
                inputSize: CGSize(width: width, height: height),
                outputSize: CGSize(width: outputWidth, height: outputHeight),
                followFactor: CGFloat(smartFramingSettings.smoothness.followFactor),
                progressHandler: { p in progressHandler(p * 0.4, "解析中...") }
            )
        }
        
        // ── コンポジション作成 + エクスポート（第2パス）──
        let progressOffset = smartFramingSettings.enabled ? 0.4 : 0.0
        let progressScale  = smartFramingSettings.enabled ? 0.6 : 1.0
        
        let (composition, videoComposition) = try await createComposition(
            asset: asset,
            videoTrack: videoTrack,
            inputSize: CGSize(width: width, height: height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            frameDuration: exportSettings.frameRate.frameDuration,
            smartFramingSettings: smartFramingSettings,
            precomputedOffsets: precomputedOffsets,
            letterboxMode: letterboxMode
            , hdrConversionEnabled: hdrConversionEnabled,
            hdrTarget: hdrTarget
        )
        
        // エクスポート
        try await exportVideo(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL,
            bitrate: exportSettings.bitrate,
            encodingMode: exportSettings.encodingMode,
            codec: exportSettings.codec,
            progressHandler: { p in
                progressHandler(progressOffset + p * progressScale, "変換中...")
            }
        )
    }

    private func createComposition(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        inputSize: CGSize,
        outputSize: CGSize,
        frameDuration: CMTime,
        smartFramingSettings: SmartFramingSettings,
        precomputedOffsets: [CGPoint]? = nil,
        letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
        , hdrConversionEnabled: Bool = false,
        hdrTarget: CustomVideoCompositionInstruction.HDRTarget = .sRGB
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
        videoComposition.frameDuration = frameDuration
        
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
            inputSize: inputSize,
            precomputedOffsets: precomputedOffsets
        )
        instruction.letterboxMode = letterboxMode
        instruction.hdrConversionEnabled = hdrConversionEnabled
        instruction.hdrTarget = hdrTarget
        
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
        encodingMode: VideoExportSettings.EncodingMode,
        codec: VideoExportSettings.Codec,
        progressHandler: @escaping (Double) -> Void
    ) async throws {

        // AVAssetReader セットアップ
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw VideoProcessorError.exportFailed
        }

        let renderSize = videoComposition.renderSize

        // ビデオ読み込み: カスタムVideoCompositionを適用して読む
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoProcessorError.exportFailed }
        reader.add(videoOutput)

        // オーディオ読み込み
        var audioOutput: AVAssetReaderTrackOutput? = nil
        if let audioTrack = composition.tracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
            ])
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                audioOutput = aOut
            }
        }

        // AVAssetWriter セットアップ
        let fileType: AVFileType = (codec == .prores422VT) ? .mov : .mp4
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw VideoProcessorError.exportFailed
        }
        writer.shouldOptimizeForNetworkUse = true

        // Safety: if ProRes was requested but no ProRes encoder is available, fail early
        if codec == .prores422VT && !VideoProcessor.isHardwareEncoderAvailable(for: .prores422VT) {
            throw VideoProcessorError.unsupportedFormat
        }

        // ビデオ出力設定（コーデック選択、エンコードモード適用）
        let videoBitrate = bitrate * 1_000_000
        var compressionProps: [String: Any] = [:]
        var videoCodecType: AVVideoCodecType = .hevc
        switch codec {
        case .h264, .h264VT:
            videoCodecType = .h264
            compressionProps[AVVideoAverageBitRateKey] = videoBitrate
        case .h265, .h265VT:
            videoCodecType = .hevc
            compressionProps[AVVideoAverageBitRateKey] = videoBitrate
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel
        case .prores422VT:
            // ProRes: bitrate not applicable; prefer quality-oriented settings
            // Use rawValue fallback for SDKs that don't expose a typed constant
            videoCodecType = AVVideoCodecType(rawValue: "apcn")
        }

        // エンコードモードごとのプロパティ調整
        switch encodingMode {
        case .cbr:
            compressionProps[AVVideoAllowFrameReorderingKey]  = false
            compressionProps[AVVideoMaxKeyFrameIntervalKey]   = 1
        case .abr:
            compressionProps[AVVideoExpectedSourceFrameRateKey] = 30
        case .vbr:
            break
        }

        // Note: Some compression properties (like AVVideoEncoderSpecificationKey) are not
        // accepted by AVAssetWriterInput for many codecs (causes ObjC exception). We no
        // longer inject AVVideoEncoderSpecificationKey here. To request hardware encoders
        // you must use VideoToolbox directly (VTCompressionSession) or rely on system
        // defaults; the UI already disables VT options when unsupported.
        switch encodingMode {
        case .cbr:
            // CBR近似: フレーム並び替えなし + キーフレーム間隔1
            compressionProps[AVVideoAllowFrameReorderingKey]  = false
            compressionProps[AVVideoMaxKeyFrameIntervalKey]   = 1
        case .abr:
            // ABR: 期待フレームレートを明示してビットレートを安定化
            compressionProps[AVVideoExpectedSourceFrameRateKey] = 30
        case .vbr:
            break  // デフォルトのVBR動作
        }
        // If non-VT h264/h265 was selected we want to force software (CPU) encoding.
        // The safest way is to use VideoToolbox's VTCompressionSession with an
        // encoder specification that does not require hardware acceleration,
        // then append the compressed samples into AVAssetWriter as passthrough
        // compressed CMSampleBuffer objects.
        let useSoftwareVT: Bool = (codec == .h264 || codec == .h265)

        var videoInput: AVAssetWriterInput
        var usingVTCompressionSession = false

        // Create video input with compression properties. Avoid injecting
        // AVVideoEncoderSpecificationKey here because it's unsupported for some
        // codecs (causes ObjC exceptions). Forcing a software-only path requires
        // a separate VTCompressionSession-based implementation.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodecType,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoProcessorError.exportFailed }
        writer.add(videoInput)

        // オーディオ出力設定（AAC 192kbps）
        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }

        // 総再生時間（プログレス計算用）
        let durationSeconds = composition.duration.seconds

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // キャンセル時に reader を即座に止める
        // → copyNextSampleBuffer() が nil を返してコールバックが自然終了する
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in

                // ビデオトラック
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video.write")) {
                            while videoInput.isReadyForMoreMediaData {
                                guard let sample = videoOutput.copyNextSampleBuffer() else {
                                    // reader がキャンセルされると nil が返る → 正常終了扱い
                                    videoInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                                videoInput.append(sample)

                                // プログレス更新
                                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                if durationSeconds > 0 {
                                    let p = min(pts / durationSeconds, 0.99)
                                    Task { @MainActor in progressHandler(p) }
                                }
                            }
                        }
                    }
                }

                // オーディオトラック
                if let aOut = audioOutput, let aIn = audioInput {
                    group.addTask {
                        try await withCheckedThrowingContinuation { continuation in
                            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.write")) {
                                while aIn.isReadyForMoreMediaData {
                                    guard let sample = aOut.copyNextSampleBuffer() else {
                                        aIn.markAsFinished()
                                        continuation.resume()
                                        return
                                    }
                                    aIn.append(sample)
                                }
                            }
                        }
                    }
                }

                try await group.waitForAll()
            }
        } onCancel: {
            // ← ここが即時実行される（メインスレッド待ち不要）
            reader.cancelReading()
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            writer.cancelWriting()
        }

        // キャンセルチェック
        if Task.isCancelled || reader.status == .cancelled || writer.status == .cancelled {
            // 未完了ファイルを削除
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoProcessorError.cancelled
        }

        // 書き出し完了
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? VideoProcessorError.exportFailed
        }

        await MainActor.run { progressHandler(1.0) }
    }
}
