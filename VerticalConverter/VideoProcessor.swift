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
            return "Invalid input video"
        case .compositionFailed:
            return "Failed to compose video"
        case .exportFailed:
            return "Failed to export video"
        case .unsupportedFormat:
            return "Unsupported video format"
        case .cancelled:
            return "Conversion cancelled"
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
                progressHandler: { p in progressHandler(p * 0.4, "Analyzing...") }
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
                progressHandler(progressOffset + p * progressScale, "Converting...")
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
        if !reader.canAdd(videoOutput) {
            throw VideoProcessorError.exportFailed
        }
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
        // accepted by AVAssetWriterInput for many codecs (causes ObjC exception). To
        // request a software-only encoder we use VTCompressionSession directly; the
        // UI already disables VT options when unsupported.
        // If non-VT h264/h265 was selected we want to force software (CPU) encoding.
        // The safest way is to use VideoToolbox's VTCompressionSession with an
        // encoder specification that does not require hardware acceleration,
        // then append the compressed samples into AVAssetWriter as passthrough
        // compressed CMSampleBuffer objects.
        let useSoftwareVT: Bool = (codec == .h264 || codec == .h265)

        

        var videoInput: AVAssetWriterInput? = nil
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

        if useSoftwareVT {
            // For software VT (we'll produce compressed CMSampleBuffers),
            // delay creating/adding the passthrough AVAssetWriterInput until
            // we have a compressed sample to obtain its format description.
            videoInput = nil
        } else {
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vIn.expectsMediaDataInRealTime = false
            if !writer.canAdd(vIn) {
                throw VideoProcessorError.exportFailed
            }
            writer.add(vIn)
            videoInput = vIn
        }
        

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
            // For software VT path, delay adding audio input until writer is started
            if !useSoftwareVT {
                if writer.canAdd(aIn) {
                    writer.add(aIn)
                    audioInput = aIn
                }
            } else {
                audioInput = aIn
            }
        }

        // 総再生時間（プログレス計算用）
        let durationSeconds = composition.duration.seconds

        
        reader.startReading()
        // If not using software VT, start writer immediately. Otherwise we'll
        // start writer after receiving first compressed sample and adding inputs.
        if !useSoftwareVT {
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }

        var writerStarted = !useSoftwareVT

        // キャンセル時に reader を即座に止める
        // → copyNextSampleBuffer() が nil を返してコールバックが自然終了する
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in

                // ビデオトラック
                group.addTask {
                    // If software VT encoding requested, use VTCompressionSession to
                    // produce compressed CMSampleBuffer objects and feed them to a
                    // passthrough AVAssetWriterInput (outputSettings: nil).
                    if codec == .h264 || codec == .h265 {
                        try await withCheckedThrowingContinuation { continuation in
                            let encodeQueue = DispatchQueue(label: "vt.encode")
                            let appendQueue = DispatchQueue(label: "video.write")

                            class VTEncoderContext {
                                let bufferLock = DispatchQueue(label: "buffer.lock")
                                var compressedBuffers: [CMSampleBuffer] = []
                                var compressedBuffersCount: Int = 0
                                var encodingFinished: Bool = false
                                var readingFinished: Bool = false
                                var didResumeContinuation: Bool = false
                            }
                            let context = VTEncoderContext()

                            // Create passthrough writer input (expects compressed samples)
                            // videoInput is already created as passthrough earlier when needed.

                            // VTCompressionSession callback
                            let callback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                                guard let ref = outputCallbackRefCon else { return }
                                let ctx = Unmanaged<AnyObject>.fromOpaque(ref).takeUnretainedValue() as! VTEncoderContext
                                guard status == noErr, let sbuf = sampleBuffer else {
                                    ctx.bufferLock.async { ctx.encodingFinished = true }
                                    return
                                }
                                // Append sampleBuffer to buffer (Swift ARC manages retention)
                                ctx.bufferLock.async {
                                    ctx.compressedBuffers.append(sbuf)
                                    ctx.compressedBuffersCount += 1
                                    
                                }
                            }

                            // Encoder specification: request software encoder when possible
                            let encoderSpec: CFDictionary = [
                                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanFalse
                            ] as CFDictionary

                            var session: VTCompressionSession? = nil
                            let codecType: CMVideoCodecType = (codec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
                            // Retain context and pass as refcon to callback
                            let refconPtr = Unmanaged.passRetained(context as AnyObject).toOpaque()
                            var status = VTCompressionSessionCreate(allocator: nil,
                                                                     width: Int32(renderSize.width),
                                                                     height: Int32(renderSize.height),
                                                                     codecType: codecType,
                                                                     encoderSpecification: encoderSpec,
                                                                     imageBufferAttributes: nil,
                                                                     compressedDataAllocator: nil,
                                                                     outputCallback: callback,
                                                                     refcon: refconPtr,
                                                                     compressionSessionOut: &session)
                            guard status == noErr, let compSession = session else {
                                Unmanaged<AnyObject>.fromOpaque(refconPtr).release()
                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                return
                            }

                            // Configure session properties
                            var bitrateBps = Int32(bitrate * 1_000_000)
                            if bitrateBps <= 0 { bitrateBps = 1_000_000 }
                            if let cfNum = CFNumberCreate(nil, .sInt32Type, &bitrateBps) {
                                status = VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_AverageBitRate, value: cfNum)
                                _ = (status != noErr)
                            }
                            // set expected frame rate if ABR specified
                            if encodingMode == .abr {
                                var fr = Int32(30)
                                _ = VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: CFNumberCreate(nil, .sInt32Type, &fr))
                            }
                            if encodingMode == .cbr {
                                var maxKey = Int32(1)
                                _ = VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: CFNumberCreate(nil, .sInt32Type, &maxKey))
                                let allowReorder = kCFBooleanFalse
                                _ = VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: allowReorder)
                            }

                            VTCompressionSessionPrepareToEncodeFrames(compSession)

                            // Writer append loop will be created after the passthrough
                            // videoInput is instantiated (after receiving first compressed sample).

                            // Read frames, feed to encoder
                            encodeQueue.async {
                                while true {
                                    if Task.isCancelled { break }
                                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                                        // finished reading
                                        context.readingFinished = true
                                        break
                                    }
                                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                                    // Prefer using the source sample duration if available
                                    var duration = CMSampleBufferGetDuration(sample)
                                    if duration == CMTime.invalid || duration == CMTime.zero {
                                        duration = videoComposition.frameDuration
                                    }
                                    var flags: VTEncodeInfoFlags = []
                                    let encodeStatus = VTCompressionSessionEncodeFrame(compSession,
                                                                                      imageBuffer: pixelBuffer,
                                                                                      presentationTimeStamp: pts,
                                                                                      duration: duration,
                                                                                      frameProperties: nil,
                                                                                      sourceFrameRefcon: nil,
                                                                                      infoFlagsOut: &flags)
                                    if encodeStatus != noErr {
                                        // mark finished and resume continuation once
                                        context.bufferLock.async {
                                            context.encodingFinished = true
                                            if !context.didResumeContinuation {
                                                context.didResumeContinuation = true
                                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                            }
                                        }
                                        break
                                    }

                                    // progress update (based on input PTS)
                                    let ptsSeconds = pts.seconds
                                    if durationSeconds > 0 {
                                        let p = min(ptsSeconds / durationSeconds, 0.99)
                                        Task { @MainActor in progressHandler(p) }
                                    }

                                    // Throttle if output buffer grows too large
                                    var shouldThrottle = false
                                    context.bufferLock.sync {
                                        shouldThrottle = context.compressedBuffers.count > 120
                                    }
                                    if shouldThrottle {
                                        Thread.sleep(forTimeInterval: 0.01)
                                    }

                                    // If we haven't started the writer (software VT path),
                                    // wait until we have the first compressed sample and
                                    // then create the passthrough input with a sourceFormatHint
                                    if !writerStarted {
                                        var firstSbuf: CMSampleBuffer? = nil
                                        context.bufferLock.sync {
                                            if !context.compressedBuffers.isEmpty {
                                                firstSbuf = context.compressedBuffers.first
                                            }
                                        }
                                        if let fs = firstSbuf, let fmt = CMSampleBufferGetFormatDescription(fs) {
                                            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                                            vIn.expectsMediaDataInRealTime = false
                                                if writer.canAdd(vIn) {
                                                writer.add(vIn)
                                                videoInput = vIn
                                                // Add audio input if it was deferred
                                                if let aIn = audioInput {
                                                    if writer.canAdd(aIn) {
                                                        writer.add(aIn)
                                                    } else {
                                                        
                                                    }
                                                }
                                                // Start writer session now
                                                writer.startWriting()
                                                writer.startSession(atSourceTime: .zero)
                                                writerStarted = true

                                                // Register append loop for the newly created video input
                                                vIn.requestMediaDataWhenReady(on: appendQueue) {
                                                    while vIn.isReadyForMoreMediaData {
                                                        var next: CMSampleBuffer? = nil
                                                        context.bufferLock.sync {
                                                            if !context.compressedBuffers.isEmpty {
                                                                next = context.compressedBuffers.removeFirst()
                                                            }
                                                        }
                                                        if let sb = next {
                                                            let appended = vIn.append(sb)
                                                            if !appended {
                                                                
                                                            }
                                                        } else if context.encodingFinished {
                                                            vIn.markAsFinished()
                                                            continuation.resume()
                                                            return
                                                        } else {
                                                            break
                                                        }
                                                    }
                                                }
                                            } else {
                                                context.bufferLock.async {
                                                    context.encodingFinished = true
                                                    if !context.didResumeContinuation {
                                                        context.didResumeContinuation = true
                                                        continuation.resume(throwing: VideoProcessorError.exportFailed)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // Finish encoding
                                VTCompressionSessionCompleteFrames(compSession, untilPresentationTimeStamp: CMTime.invalid)
                                // Wait until buffer is drained in writer loop; mark encodingFinished
                                context.bufferLock.async {
                                    context.encodingFinished = true
                                }
                                // Invalidate session
                                VTCompressionSessionInvalidate(compSession)
                                // Release retained context
                                Unmanaged<AnyObject>.fromOpaque(refconPtr).release()
                            }
                        }
                    } else {
                        try await withCheckedThrowingContinuation { continuation in
                            guard let vIn = videoInput else {
                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                return
                            }
                            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "video.write")) {
                                while vIn.isReadyForMoreMediaData {
                                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                                        // reader がキャンセルされると nil が返る → 正常終了扱い
                                        vIn.markAsFinished()
                                        continuation.resume()
                                        return
                                    }
                                    vIn.append(sample)

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
                }

                // オーディオトラック
                if let aOut = audioOutput, let aIn = audioInput {
                    group.addTask {
                        try await withCheckedThrowingContinuation { continuation in
                            // If using software VT path, ensure writer has started and
                            // inputs have been added before we begin appending audio.
                            while useSoftwareVT && !writerStarted {
                                Thread.sleep(forTimeInterval: 0.01)
                            }
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
              videoInput?.markAsFinished()
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
