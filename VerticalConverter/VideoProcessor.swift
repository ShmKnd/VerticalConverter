//
//  VideoProcessor.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import Foundation
@preconcurrency import AVFoundation
import CoreImage
import VideoToolbox
import CoreMedia

// Registry to track VTCompressionSession and refcon pointers so we can
// invalidate them from outside encoder scope (best-effort on cancellation).
private final class VTSessionRegistry {
    static let shared = VTSessionRegistry()
    private let q = DispatchQueue(label: "vt.session.registry")
    private var sessions: [VTCompressionSession] = []
    private var refcons: [UnsafeMutableRawPointer] = []

    func add(session: VTCompressionSession, refcon: UnsafeMutableRawPointer) {
        q.sync {
            sessions.append(session)
            refcons.append(refcon)
            NSLog("VTSessionRegistry: added session \(session) refcon=\(refcon)")
        }
    }

    func remove(refcon: UnsafeMutableRawPointer) {
        q.sync {
            if let idx = refcons.firstIndex(where: { $0 == refcon }) {
                // Invalidate and release just in case
                let s = sessions[idx]
                VTCompressionSessionInvalidate(s)
                // Release retained refcon
                Unmanaged<AnyObject>.fromOpaque(refcon).release()
                sessions.remove(at: idx)
                refcons.remove(at: idx)
                NSLog("VTSessionRegistry: removed refcon=\(refcon) and invalidated session")
            }
        }
    }

    func dumpInfo() {
        q.sync {
            NSLog("VTSessionRegistry: dump - sessions=\(sessions.count), refcons=\(refcons.count)")
        }
    }

    func invalidateAll() {
        q.sync {
            for s in sessions {
                VTCompressionSessionInvalidate(s)
            }
            // Release any retained refcons
            for ref in refcons {
                NSLog("VTSessionRegistry: releasing refcon \(ref)")
                Unmanaged<AnyObject>.fromOpaque(ref).release()
            }
            sessions.removeAll()
            refcons.removeAll()
        }
    }
}

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

    /// Inspect the first video track of a composition to determine whether its
    /// content is HDR and, if so, which transfer function / primaries it uses.
    private static func detectHDRInfo(from composition: AVMutableComposition)
        -> (isHDR: Bool, transferFunction: String, colorPrimaries: String, ycbcrMatrix: String)
    {
        let sdrResult = (false,
                         AVVideoTransferFunction_ITU_R_709_2,
                         AVVideoColorPrimaries_ITU_R_709_2,
                         AVVideoYCbCrMatrix_ITU_R_709_2)

        guard let videoTrack = composition.tracks(withMediaType: .video).first,
              let desc = videoTrack.formatDescriptions.first,
              let exts = CMFormatDescriptionGetExtensions(desc as! CMFormatDescription) as? [String: Any]
        else { return sdrResult }

        let transferRaw = (exts[kCVImageBufferTransferFunctionKey as String] as? String) ?? ""
        let primariesRaw = (exts[kCVImageBufferColorPrimariesKey as String] as? String) ?? ""
        let matrixRaw   = (exts[kCVImageBufferYCbCrMatrixKey as String] as? String) ?? ""
        let tLower = transferRaw.lowercased()

        let isHDR = tLower.contains("2084") || tLower.contains("pq") ||
                    tLower.contains("hlg")  || tLower.contains("st2084")
        guard isHDR else { return sdrResult }

        let transferFunction: String
        if tLower.contains("hlg") {
            transferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
        } else {
            transferFunction = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        }

        let pLower = primariesRaw.lowercased()
        let primaries: String
        if pLower.contains("2020")      { primaries = AVVideoColorPrimaries_ITU_R_2020 }
        else if pLower.contains("p3")   { primaries = "P3-D65" }
        else                            { primaries = AVVideoColorPrimaries_ITU_R_709_2 }

        let mLower = matrixRaw.lowercased()
        let matrix: String = mLower.contains("2020") ? AVVideoYCbCrMatrix_ITU_R_2020
                                                      : AVVideoYCbCrMatrix_ITU_R_709_2

        return (true, transferFunction, primaries, matrix)
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
        // Detect HDR characteristics from the composition track's format description
        // so we can configure the compositor's static properties BEFORE it's instantiated.
        let (isHDR, detTransfer, detPrimaries, detMatrix) =
            VideoProcessor.detectHDRInfo(from: composition)
        
        // Set ALL static configuration BEFORE assigning customVideoCompositorClass.
        // AVFoundation queries sourcePixelBufferAttributes and
        // requiredPixelBufferAttributesForRenderContext immediately after init(),
        // before any startRequest() call.
        VerticalVideoCompositor.staticSourceIsHDR = isHDR
        VerticalVideoCompositor.staticHDRConversionEnabled = hdrConversionEnabled
        VerticalVideoCompositor.staticTransferFunction = detTransfer
        VerticalVideoCompositor.staticColorPrimaries = detPrimaries
        VerticalVideoCompositor.staticYCbCrMatrix = detMatrix
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

        // Determine whether composition requests HDR->SDR conversion and the target color space.
        let hdrConversionRequested = (videoComposition.instructions.first as? CustomVideoCompositionInstruction)?.hdrConversionEnabled ?? false
        let hdrTarget = (videoComposition.instructions.first as? CustomVideoCompositionInstruction)?.hdrTarget ?? .sRGB

        // Detect input HDR characteristics from the composition track's format description.
        let (isHDRInput, detectedTransfer, detectedPrimaries, detectedMatrix) =
            VideoProcessor.detectHDRInfo(from: composition)
        NSLog("VideoProcessor: isHDRInput=\(isHDRInput) hdrConversionRequested=\(hdrConversionRequested)")

        // ビデオ読み込み: カスタム VideoComposition を適用して読む
        //
        // CRITICAL: ここで指定するフォーマットは、コンポジターの
        // requiredPixelBufferAttributesForRenderContext が返すフォーマットと
        // 必ず一致させること。不一致があると AVFoundation が暗黙の
        // ピクセルフォーマット変換を行い、フレーム 0 のガンマ/色が狂う原因になる。
        //
        //  • HDR パススルー → 64RGBAHalf (HDR 値を保持)
        //  • HDR→SDR       → 32BGRA (SDR 出力)
        //  • SDR            → 32BGRA (SDR 出力)
        // ProRes VT は float RGBA を受け付けないため HDR でも BGRA を使用
        let isHDRPassthrough = isHDRInput && !hdrConversionRequested && codec != .prores422VT
        let preferredPixelFormat: OSType = isHDRPassthrough
            ? kCVPixelFormatType_64RGBAHalf
            : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: preferredPixelFormat
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        if !reader.canAdd(videoOutput) {
            throw VideoProcessorError.exportFailed
        }
        reader.add(videoOutput)
        // Serialize access to copyNextSampleBuffer to avoid concurrent calls
        let videoReadQueue = DispatchQueue(label: "video.read")

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
            // Main10 (10-bit) only when preserving HDR; Main (8-bit) for SDR or HDR->SDR.
            let chosenProfile = (isHDRInput && !hdrConversionRequested)
                ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : kVTProfileLevel_HEVC_Main_AutoLevel
            compressionProps[AVVideoProfileLevelKey] = chosenProfile
            NSLog("VideoProcessor: HEVC profile chosen = \(chosenProfile as CFString)")
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

        // Add color properties to writer settings so that color metadata is
        // preserved/declared. If the composition requested HDR->SDR conversion,
        // emit Rec.709/sRGB properties; otherwise advertise BT.2020/PQ for HDR preservation.
        var videoSettingsMutable = videoSettings
        // 2軸分岐: isHDRInput × hdrConversionRequested
        // HDR入力でパススルー → 入力素材の色空間メタデータをそのまま使用
        // それ以外（SDR入力、またはHDR→SDR変換ON）→ Rec.709で書き出し
        if isHDRInput && !hdrConversionRequested {
            let colorProps: [String: Any] = [
                AVVideoColorPrimariesKey: detectedPrimaries,
                AVVideoTransferFunctionKey: detectedTransfer,
                AVVideoYCbCrMatrixKey: detectedMatrix
            ]
            videoSettingsMutable[AVVideoColorPropertiesKey] = colorProps
        } else {
            // SDR input passthrough / HDR→SDR: use the target transfer function.
            // For HDR→SDR with sRGB target use "IEC_sRGB"; otherwise Rec.709.
            let transferFunction: String
            if hdrConversionRequested {
                transferFunction = (hdrTarget == .sRGB)
                    ? (kCVImageBufferTransferFunction_sRGB as String)
                    : AVVideoTransferFunction_ITU_R_709_2
            } else {
                transferFunction = AVVideoTransferFunction_ITU_R_709_2
            }
            let colorProps: [String: Any] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: transferFunction,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
            videoSettingsMutable[AVVideoColorPropertiesKey] = colorProps
        }

        if useSoftwareVT {
            // For software VT (we'll produce compressed CMSampleBuffers),
            // delay creating/adding the passthrough AVAssetWriterInput until
            // we have a compressed sample to obtain its format description.
            videoInput = nil
        } else {
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettingsMutable)
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


        // キャンセル用トークン（DispatchQueueで保護）
        class CancelToken {
            private let q = DispatchQueue(label: "cancel.token.lock")
            private var _cancelled: Bool = false
            func cancel() { q.sync { _cancelled = true } }
            func isCancelled() -> Bool { q.sync { _cancelled } }
        }
        let cancelToken = CancelToken()

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
                            // captureable references for cancellation
                            var localCompSession: VTCompressionSession? = nil
                            var localRefconPtr: UnsafeMutableRawPointer? = nil
                            // Continuation safety: ensure continuation.resume is only called once
                            let contLock = DispatchQueue(label: "vt.cont.lock")
                            var contDidResume = false
                            func safeResume(_ block: @escaping () -> Void) {
                                contLock.sync {
                                    if !contDidResume {
                                        contDidResume = true
                                        block()
                                    }
                                }
                            }

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
                            localRefconPtr = refconPtr
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
                                if let ref = localRefconPtr { Unmanaged<AnyObject>.fromOpaque(ref).release() }
                                safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                return
                            }
                                localCompSession = compSession
                                // Ensure VTCompressionSession uses the intended HEVC profile
                                // (Main vs Main10) so the compressed sample format matches
                                // the writer expectations. This avoids format mismatches
                                // that cause writer.canAdd to fail and produce audio-only outputs.
                                if codec == .h265 {
                                    let profile: CFString = (isHDRInput && !hdrConversionRequested)
                                        ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                        : kVTProfileLevel_HEVC_Main_AutoLevel
                                    VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
                                    NSLog("VideoProcessor: VTCompressionSession profile set = \(profile)")
                                }
                                // For HDR passthrough, embed color metadata into the compressed bitstream
                                // so the passthrough AVAssetWriterInput picks up the correct colorimetry.
                                if isHDRInput && !hdrConversionRequested {
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_ColorPrimaries,
                                        value: detectedPrimaries as CFString)
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_TransferFunction,
                                        value: detectedTransfer as CFString)
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_YCbCrMatrix,
                                        value: detectedMatrix as CFString)
                                    NSLog("VideoProcessor: VT color metadata set: primaries=\(detectedPrimaries) transfer=\(detectedTransfer)")
                                }
                                // Register session so cancellation handler can invalidate it
                                VTSessionRegistry.shared.add(session: compSession, refcon: refconPtr)

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
                                    if cancelToken.isCancelled() {
                                        // Best-effort: complete and invalidate local compression session immediately
                                        if let comp = localCompSession {
                                            NSLog("VideoProcessor: encode loop cancellation - completing/invalidate local VT session")
                                            VTCompressionSessionCompleteFrames(comp, untilPresentationTimeStamp: CMTime.invalid)
                                            VTCompressionSessionInvalidate(comp)
                                            // Also remove from shared registry if present
                                            if let ref = localRefconPtr { VTSessionRegistry.shared.remove(refcon: ref) }
                                        }
                                        break
                                    }
                                    guard let sample = videoReadQueue.sync(execute: { videoOutput.copyNextSampleBuffer() }) else {
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
                                                safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
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
                                            // Build writer settings based on the previously computed
                                            // videoSettingsMutable, but prefer to add explicit
                                            // color properties discovered from the sample's
                                            // format description so the writer does not default
                                            // to Rec.709 for HDR content.
                                            var settingsToUse = videoSettingsMutable
                                            if let exts = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] {
                                                var colorProps: [String: Any] = [:]
                                                if let prim = exts[kCVImageBufferColorPrimariesKey as String] as? String {
                                                    let lower = prim.lowercased()
                                                    if lower.contains("2020") { colorProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_2020 }
                                                    else if lower.contains("p3") { colorProps[AVVideoColorPrimariesKey] = "P3-D65" }
                                                    else { colorProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_709_2 }
                                                }
                                                if let transfer = exts[kCVImageBufferTransferFunctionKey as String] as? String {
                                                    let lower = transfer.lowercased()
                                                    if lower.contains("hlg") { colorProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_2100_HLG }
                                                    else if lower.contains("pq") || lower.contains("2084") { colorProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_SMPTE_ST_2084_PQ }
                                                    else { colorProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2 }
                                                }
                                                if let matrix = exts[kCVImageBufferYCbCrMatrixKey as String] as? String {
                                                    let lower = matrix.lowercased()
                                                    if lower.contains("2020") { colorProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_2020 }
                                                    else { colorProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_709_2 }
                                                }
                                                if !colorProps.isEmpty {
                                                    settingsToUse[AVVideoColorPropertiesKey] = colorProps
                                                }
                                            }

                                            // We're feeding compressed CMSampleBuffer objects from VT, so
                                            // this must be a passthrough input: use `outputSettings: nil`.
                                            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                                            vIn.expectsMediaDataInRealTime = false
                                            NSLog("VideoProcessor: canAdd video: \(writer.canAdd(vIn))")
                                            if writer.canAdd(vIn) {
                                                writer.add(vIn)
                                                videoInput = vIn
                                                // Add audio input if it was deferred
                                                if let aIn = audioInput {
                                                    if writer.canAdd(aIn) {
                                                        writer.add(aIn)
                                                    }
                                                }
                                                // Start writer session now
                                                writer.startWriting()
                                                writer.startSession(atSourceTime: .zero)
                                                writerStarted = true

                                                // Register append loop for the newly created video input
                                                vIn.requestMediaDataWhenReady(on: appendQueue) {
                                                    while vIn.isReadyForMoreMediaData {
                                                        if cancelToken.isCancelled() {
                                                            vIn.markAsFinished()
                                                            context.bufferLock.async {
                                                                context.encodingFinished = true
                                                                if !context.didResumeContinuation {
                                                                    context.didResumeContinuation = true
                                                                    safeResume({ continuation.resume(throwing: VideoProcessorError.cancelled) })
                                                                }
                                                            }
                                                            return
                                                        }
                                                        var next: CMSampleBuffer? = nil
                                                        context.bufferLock.sync {
                                                            if !context.compressedBuffers.isEmpty {
                                                                next = context.compressedBuffers.removeFirst()
                                                            }
                                                        }
                                                        if let sb = next {
                                                            let appended = vIn.append(sb)
                                                            if !appended {
                                                                context.bufferLock.async {
                                                                    context.encodingFinished = true
                                                                    if !context.didResumeContinuation {
                                                                        context.didResumeContinuation = true
                                                                        safeResume({
                                                                            if cancelToken.isCancelled() {
                                                                                continuation.resume(throwing: VideoProcessorError.cancelled)
                                                                            } else if writer.status == .failed {
                                                                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                                                            } else {
                                                                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                                                            }
                                                                        })
                                                                    }
                                                                }
                                                                return
                                                            }
                                                        } else if context.encodingFinished {
                                                            vIn.markAsFinished()
                                                            if !context.didResumeContinuation {
                                                                context.didResumeContinuation = true
                                                                safeResume({ continuation.resume() })
                                                            }
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
                                                        safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
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
                                // Release retained context via registry to avoid double-release
                                if let ref = localRefconPtr {
                                    VTSessionRegistry.shared.remove(refcon: ref)
                                }
                                localRefconPtr = nil
                                localCompSession = nil
                            }
                        }
                    } else {
                        try await withCheckedThrowingContinuation { continuation in
                            let contLock = DispatchQueue(label: "cont.lock.video")
                            var didResume = false
                            func safeResume(_ resumeBlock: @escaping () -> Void) {
                                contLock.sync {
                                    if !didResume {
                                        didResume = true
                                        resumeBlock()
                                    }
                                }
                            }

                            guard let vIn = videoInput else {
                                safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                return
                            }
                            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "video.write")) {
                                while vIn.isReadyForMoreMediaData {
                                    if cancelToken.isCancelled() {
                                        vIn.markAsFinished()
                                        safeResume({ continuation.resume(throwing: VideoProcessorError.cancelled) })
                                        return
                                    }
                                    guard let sample = videoReadQueue.sync(execute: { videoOutput.copyNextSampleBuffer() }) else {
                                        // reader がキャンセルされると nil が返る → 正常終了扱い
                                        vIn.markAsFinished()
                                        safeResume({ continuation.resume() })
                                        return
                                    }
                                    let appended = vIn.append(sample)
                                    if !appended {
                                        // Append failed — likely writer was cancelled or failed
                                        safeResume({
                                            if cancelToken.isCancelled() {
                                                continuation.resume(throwing: VideoProcessorError.cancelled)
                                            } else if writer.status == .failed {
                                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                            } else {
                                                continuation.resume(throwing: VideoProcessorError.exportFailed)
                                            }
                                        })
                                        return
                                    }

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
                            let contLock = DispatchQueue(label: "cont.lock.audio")
                            var didResume = false
                            func safeResume(_ resumeBlock: @escaping () -> Void) {
                                contLock.sync {
                                    if !didResume {
                                        didResume = true
                                        resumeBlock()
                                    }
                                }
                            }
                            // If using software VT path, ensure writer has started and
                            // inputs have been added before we begin appending audio.
                            while useSoftwareVT && !writerStarted {
                                if cancelToken.isCancelled() { safeResume({ continuation.resume(throwing: VideoProcessorError.cancelled) }); return }
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.write")) {
                                while aIn.isReadyForMoreMediaData {
                                    if cancelToken.isCancelled() {
                                        aIn.markAsFinished()
                                        safeResume({ continuation.resume(throwing: VideoProcessorError.cancelled) })
                                        return
                                    }
                                    guard let sample = aOut.copyNextSampleBuffer() else {
                                        aIn.markAsFinished()
                                        safeResume({ continuation.resume() })
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
                    NSLog("VideoProcessor: cancellation handler invoked")
                    // 1) Signal internal cancel token so encode loops see cancellation quickly
                    NSLog("VideoProcessor: setting cancel token (onCancel)")
                    cancelToken.cancel()

                    // 2) Invalidate VT sessions to stop encoders (best-effort)
                    NSLog("VideoProcessor: invalidating VT sessions via registry (onCancel)")
                    VTSessionRegistry.shared.invalidateAll()
                    // Small pause to let invalidation propagate to encoder threads
                    Thread.sleep(forTimeInterval: 0.1)

                    // 3) Mark writer inputs finished (best-effort) before cancelling reader/writer
                    NSLog("VideoProcessor: marking writer inputs finished (onCancel)")
                    videoInput?.markAsFinished()
                    audioInput?.markAsFinished()

                    // 4) Stop reader and cancel writer
                    reader.cancelReading()
                    writer.cancelWriting()

                    // Diagnostic dump
                    NSLog("VideoProcessor: onCancel reader.status=\(reader.status.rawValue) writer.status=\(writer.status.rawValue)")
                    VTSessionRegistry.shared.dumpInfo()

                    // Do not remove output file here; wait until writer has settled in the outer scope
                }

        // キャンセルチェック
        if Task.isCancelled || reader.status == .cancelled || writer.status == .cancelled {
            // Wait briefly for writer to settle (avoid deleting while writer is mid-state)
            var waitCount = 0
            while writer.status == .writing && waitCount < 20 {
                Thread.sleep(forTimeInterval: 0.05)
                waitCount += 1
            }
            NSLog("VideoProcessor: cancellation confirmed, writer.status=\(writer.status). Removing partial output")
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoProcessorError.cancelled
        }

        // 書き出し完了: writer が実際に書き込み中であれば finish を呼ぶ
        if writer.status == .writing {
            NSLog("VideoProcessor: writer.status == .writing; calling finishWriting()")
            await writer.finishWriting()
        } else {
            NSLog("VideoProcessor: skipping finishWriting(), writer.status = \(writer.status)")
        }

        if writer.status == .failed {
            throw writer.error ?? VideoProcessorError.exportFailed
        }

        await MainActor.run { progressHandler(1.0) }
    }
}
