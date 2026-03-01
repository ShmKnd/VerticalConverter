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

    // MARK: - hev1 detection & remux

    /// Check whether the first video track of an asset uses the hev1 codec tag.
    /// hev1 stores HEVC parameter sets in-band (NAL units) which AVFoundation's
    /// composition pipeline cannot decode. We need to remux to hvc1 first.
    private static func isHev1(asset: AVAsset) async -> Bool {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = videoTrack.formatDescriptions.first else {
            return false
        }
        let fmt = desc as! CMFormatDescription
        let codecType = CMFormatDescriptionGetMediaSubType(fmt)
        let hev1FourCC: FourCharCode = 0x68657631 // 'hev1'
        NSLog("VideoProcessor: input codec FourCC = %{public}@",
              String(format: "%c%c%c%c",
                     (codecType >> 24) & 0xFF,
                     (codecType >> 16) & 0xFF,
                     (codecType >> 8) & 0xFF,
                     codecType & 0xFF))
        return codecType == hev1FourCC
    }

    /// Remux an hev1 video file to hvc1 (no re-encoding, no quality loss).
    ///
    /// hev1 stores HEVC parameter sets (VPS/SPS/PPS) in-band as NAL units.
    /// AVFoundation's composition pipeline requires hvc1, which stores them
    /// out-of-band in an hvcC configuration record.
    ///
    /// This method:
    ///  1. Reads compressed hev1 samples as-is (passthrough, no decode)
    ///  2. Extracts VPS/SPS/PPS from the format description or bitstream
    ///  3. Creates a proper hvc1 CMFormatDescription via
    ///     CMVideoFormatDescriptionCreateFromHEVCParameterSets
    ///  4. Writes samples with the correct format description
    ///
    /// Audio is copied as passthrough.
    private func remuxHev1ToHvc1(
        inputURL: URL,
        outputURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let remuxStart = CFAbsoluteTimeGetCurrent()
        NSLog("VideoProcessor: remuxing hev1 → hvc1 (proper parameter set extraction)")
        let asset = AVAsset(url: inputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessorError.invalidInput
        }

        let origDesc = videoTrack.formatDescriptions.first as! CMFormatDescription

        // ── Step 1: Determine NAL unit header length ──
        // Try the original format description; if hev1 has an hvcC box, it
        // reports the length. Default to 4 (standard for MP4/MOV).
        var nalHeaderLength: Int32 = 4
        var paramSetCountFromFmt: Int = 0
        let fmtQueryStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            origDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &paramSetCountFromFmt,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        NSLog("VideoProcessor: hev1 fmt query status=%d paramSetCount=%d nalHeaderLength=%d",
              fmtQueryStatus, paramSetCountFromFmt, nalHeaderLength)

        // ── Step 2: Try extracting parameter sets from format description ──
        var parameterSets: [Data] = []
        if fmtQueryStatus == noErr && paramSetCountFromFmt > 0 {
            for i in 0..<paramSetCountFromFmt {
                var ptr: UnsafePointer<UInt8>?
                var size: Int = 0
                let s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    origDesc,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                if s == noErr, let p = ptr, size > 0 {
                    parameterSets.append(Data(bytes: p, count: size))
                }
            }
            NSLog("VideoProcessor: extracted %d parameter sets from hev1 format description", parameterSets.count)
        }

        // ── Step 3: If format description didn't have them, parse bitstream ──
        // We need to read compressed samples to find VPS (type 32), SPS (33), PPS (34)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoProcessorError.exportFailed }
        reader.add(videoOutput)

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        var audioOutput: AVAssetReaderTrackOutput? = nil
        if let aTrack = audioTrack {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                audioOutput = aOut
            }
        }

        reader.startReading()
        guard reader.status == .reading else {
            let err = reader.error?.localizedDescription ?? "unknown"
            NSLog("VideoProcessor: hev1 remux reader failed to start: %@", err)
            throw VideoProcessorError.unsupportedFormat
        }

        // Collect initial samples and optionally parse parameter sets from them
        var collectedVideoSamples: [CMSampleBuffer] = []

        if parameterSets.isEmpty {
            NSLog("VideoProcessor: no parameter sets in format description; parsing bitstream NAL units")
            let nalLen = Int(nalHeaderLength)
            var foundVPS: Data?
            var foundSPS: Data?
            var foundPPS: Data?

            // Read up to 60 samples to find all parameter sets
            for _ in 0..<60 {
                guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                collectedVideoSamples.append(sample)

                guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                var lengthAtOffset: Int = 0
                var totalLength: Int = 0
                var bufPtr: UnsafeMutablePointer<Int8>?
                let lockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                                             lengthAtOffsetOut: &lengthAtOffset,
                                                             totalLengthOut: &totalLength,
                                                             dataPointerOut: &bufPtr)
                guard lockStatus == noErr, let rawPtr = bufPtr else { continue }

                let bytes = UnsafeRawBufferPointer(start: rawPtr, count: totalLength)
                var offset = 0
                while offset + nalLen < totalLength {
                    // Read NAL unit length (big-endian)
                    var nalUnitLength: UInt32 = 0
                    for i in 0..<nalLen {
                        nalUnitLength = (nalUnitLength << 8) | UInt32(bytes[offset + i])
                    }
                    offset += nalLen
                    let nalSize = Int(nalUnitLength)
                    guard nalSize > 0, offset + nalSize <= totalLength else { break }

                    // HEVC NAL unit type: bits 1-6 of first byte
                    let nalType = (bytes[offset] >> 1) & 0x3F
                    let nalData = Data(bytes: bytes.baseAddress!.advanced(by: offset),
                                       count: nalSize)
                    switch nalType {
                    case 32: foundVPS = nalData  // VPS
                    case 33: foundSPS = nalData  // SPS
                    case 34: foundPPS = nalData  // PPS
                    default: break
                    }

                    offset += nalSize
                }

                if foundVPS != nil && foundSPS != nil && foundPPS != nil { break }
            }

            if let vps = foundVPS { parameterSets.append(vps) }
            if let sps = foundSPS { parameterSets.append(sps) }
            if let pps = foundPPS { parameterSets.append(pps) }
            NSLog("VideoProcessor: parsed %d parameter sets from bitstream (VPS=%d SPS=%d PPS=%d)",
                  parameterSets.count,
                  foundVPS != nil ? 1 : 0,
                  foundSPS != nil ? 1 : 0,
                  foundPPS != nil ? 1 : 0)
        }

        guard parameterSets.count >= 3 else {
            NSLog("VideoProcessor: insufficient parameter sets (%d) for hvc1 format", parameterSets.count)
            throw VideoProcessorError.unsupportedFormat
        }

        // ── Step 4: Create proper hvc1 CMFormatDescription ──
        // CMVideoFormatDescriptionCreateFromHEVCParameterSets requires C arrays
        // of pointers and sizes. Build them from our Data objects.
        var hvc1Fmt: CMFormatDescription!
        do {
            let count = parameterSets.count
            // Use NSData to pin the bytes so pointers remain valid during the C API call.
            let nsDatas = parameterSets.map { $0 as NSData }
            var rawPointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            for ns in nsDatas {
                rawPointers.append(ns.bytes.assumingMemoryBound(to: UInt8.self))
                sizes.append(ns.length)
            }

            var fmt: CMFormatDescription?
            let status = rawPointers.withUnsafeBufferPointer { ptrBuf in
                sizes.withUnsafeBufferPointer { sizeBuf in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil,
                        parameterSetCount: count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: Int32(nalHeaderLength),
                        extensions: CMFormatDescriptionGetExtensions(origDesc),
                        formatDescriptionOut: &fmt
                    )
                }
            }
            guard status == noErr, let f = fmt else {
                NSLog("VideoProcessor: CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: %d", status)
                throw VideoProcessorError.exportFailed
            }
            hvc1Fmt = f
        }
        NSLog("VideoProcessor: created hvc1 format description successfully")
        let setupDone = CFAbsoluteTimeGetCurrent()
        NSLog("VideoProcessor: remux setup took %.3f s", setupDone - remuxStart)

        // ── Step 5: Set up writer ──
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: hvc1Fmt)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoProcessorError.exportFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }

        writer.startWriting()
        if writer.status != .writing {
            let err = writer.error?.localizedDescription ?? "none"
            NSLog("VideoProcessor: remux writer failed to start: status=%d error=%@", writer.status.rawValue, err)
            throw VideoProcessorError.exportFailed
        }
        writer.startSession(atSourceTime: .zero)
        NSLog("VideoProcessor: remux writer started successfully, status=%d", writer.status.rawValue)

        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds

        // Helper: rewrite a compressed CMSampleBuffer's format description
        // from hev1 to hvc1 while keeping the same compressed data.
        // This is critical — AVAssetWriterInput passthrough copies the sample's
        // own format description, not the sourceFormatHint.
        let rewriteFmt = hvc1Fmt  // capture for closure
        func rewriteSampleWithHvc1(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
            // Ensure the sample data is ready (may be lazy-loaded for passthrough)
            if !CMSampleBufferDataIsReady(sample) {
                let makeReadyStatus = CMSampleBufferMakeDataReady(sample)
                if makeReadyStatus != noErr {
                    NSLog("VideoProcessor: CMSampleBufferMakeDataReady failed: %d", makeReadyStatus)
                }
            }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else {
                let hasImageBuf = CMSampleBufferGetImageBuffer(sample) != nil
                let totalSize = CMSampleBufferGetTotalSampleSize(sample)
                let numS = CMSampleBufferGetNumSamples(sample)
                let isValid = CMSampleBufferIsValid(sample)
                let isReady = CMSampleBufferDataIsReady(sample)
                NSLog("VideoProcessor: rewrite failed - no data buffer (hasImageBuf=%d totalSize=%d numSamples=%d valid=%d ready=%d)",
                      hasImageBuf ? 1 : 0, totalSize, numS, isValid ? 1 : 0, isReady ? 1 : 0)
                return nil
            }
            let numSamples = CMSampleBufferGetNumSamples(sample)

            // Gather timing info for all samples
            var timingEntries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: numSamples)
            let timingStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: numSamples,
                                                    arrayToFill: &timingEntries,
                                                    entriesNeededOut: nil)
            // Gather sizes for all samples
            var sizeEntries = [Int](repeating: 0, count: numSamples)
            let sizeStatus = CMSampleBufferGetSampleSizeArray(sample, entryCount: numSamples,
                                              arrayToFill: &sizeEntries,
                                              entriesNeededOut: nil)

            var newSample: CMSampleBuffer?
            let status = CMSampleBufferCreate(
                allocator: nil,
                dataBuffer: dataBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: rewriteFmt,  // hvc1 instead of hev1
                sampleCount: numSamples,
                sampleTimingEntryCount: numSamples,
                sampleTimingArray: &timingEntries,
                sampleSizeEntryCount: numSamples,
                sampleSizeArray: &sizeEntries,
                sampleBufferOut: &newSample
            )
            if status != noErr {
                NSLog("VideoProcessor: CMSampleBufferCreate failed: %d (timing=%d size=%d numSamples=%d)",
                      status, timingStatus, sizeStatus, numSamples)
            }
            return status == noErr ? newSample : nil
        }

        // ── Step 6: Write all samples with hvc1 format description ──
        NSLog("VideoProcessor: remux step 6 - writing %d pre-collected + remaining samples (reader status=%d)",
              collectedVideoSamples.count, reader.status.rawValue)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    var resumed = false
                    let lock = DispatchQueue(label: "remux.cont.lock")
                    func safeResume(_ block: @escaping () -> Void) {
                        lock.sync { if !resumed { resumed = true; block() } }
                    }

                    // Use a mutable index to track which pre-collected samples
                    // still need to be written. Write them inside
                    // requestMediaDataWhenReady so we respect isReadyForMoreMediaData.
                    var collectedIndex = 0
                    let collectedCount = collectedVideoSamples.count
                    var writtenCount = 0
                    var skippedCount = 0

                    videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "remux.video")) {
                        while videoInput.isReadyForMoreMediaData {
                            autoreleasepool {
                            // First drain pre-collected samples
                            if collectedIndex < collectedCount {
                                let sample = collectedVideoSamples[collectedIndex]
                                collectedIndex += 1
                                // Skip empty format-change notification samples
                                if CMSampleBufferGetNumSamples(sample) == 0 {
                                    skippedCount += 1
                                    return  // exits autoreleasepool closure → continues while loop
                                }
                                guard let rewritten = rewriteSampleWithHvc1(sample) else {
                                    NSLog("VideoProcessor: remux rewrite failed for pre-collected sample %d", collectedIndex - 1)
                                    videoInput.markAsFinished()
                                    safeResume { cont.resume(throwing: VideoProcessorError.exportFailed) }
                                    return
                                }
                                let ok = videoInput.append(rewritten)
                                if !ok {
                                    let writerErr = writer.error?.localizedDescription ?? "none"
                                    NSLog("VideoProcessor: remux append failed for pre-collected sample, writer error=%@", writerErr)
                                    videoInput.markAsFinished()
                                    safeResume { cont.resume(throwing: VideoProcessorError.exportFailed) }
                                    return
                                }
                                writtenCount += 1
                                return  // exits autoreleasepool closure → continues while loop
                            }

                            // Then read remaining samples from reader
                            guard let sample = videoOutput.copyNextSampleBuffer() else {
                                NSLog("VideoProcessor: remux video done - written=%d skipped=%d readerStatus=%d",
                                      writtenCount, skippedCount, reader.status.rawValue)
                                if reader.status == .failed {
                                    let rErr = reader.error?.localizedDescription ?? "none"
                                    NSLog("VideoProcessor: reader failed during remux: %@", rErr)
                                }
                                videoInput.markAsFinished()
                                safeResume { cont.resume() }
                                return
                            }
                            // Skip empty format-change notification samples
                            if CMSampleBufferGetNumSamples(sample) == 0 {
                                skippedCount += 1
                                return  // exits autoreleasepool closure → continues while loop
                            }
                            guard let rewritten = rewriteSampleWithHvc1(sample) else {
                                NSLog("VideoProcessor: remux rewrite failed for streamed sample (reader status=%d)", reader.status.rawValue)
                                videoInput.markAsFinished()
                                safeResume { cont.resume(throwing: VideoProcessorError.exportFailed) }
                                return
                            }
                            let ok = videoInput.append(rewritten)
                            if !ok {
                                let writerErr = writer.error?.localizedDescription ?? "none"
                                NSLog("VideoProcessor: remux append failed, writer error=%@", writerErr)
                                videoInput.markAsFinished()
                                safeResume { cont.resume(throwing: VideoProcessorError.exportFailed) }
                                return
                            }
                            writtenCount += 1
                            if durationSeconds > 0 {
                                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                let p = min(pts / durationSeconds, 0.99)
                                Task { @MainActor in progressHandler(p) }
                            }
                            } // end autoreleasepool
                        }
                    }
                }
            }
            if let aOut = audioOutput, let aIn = audioInput {
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        var resumed = false
                        let lock = DispatchQueue(label: "remux.audio.lock")
                        func safeResume(_ block: @escaping () -> Void) {
                            lock.sync { if !resumed { resumed = true; block() } }
                        }
                        aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "remux.audio")) {
                            while aIn.isReadyForMoreMediaData {
                                guard let sample = aOut.copyNextSampleBuffer() else {
                                    aIn.markAsFinished()
                                    safeResume { cont.resume() }
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

        let writeStart = CFAbsoluteTimeGetCurrent()
        await writer.finishWriting()
        if writer.status == .failed {
            let err = writer.error?.localizedDescription ?? "none"
            NSLog("VideoProcessor: remux writer.finishWriting failed: %@", err)
            throw writer.error ?? VideoProcessorError.exportFailed
        }
        let remuxEnd = CFAbsoluteTimeGetCurrent()
        NSLog("VideoProcessor: hev1 → hvc1 remux complete — total=%.3f s (setup=%.3f write=%.3f finalize=%.3f)",
              remuxEnd - remuxStart,
              setupDone - remuxStart,
              writeStart - setupDone,
              remuxEnd - writeStart)
    }
    func convertToVertical(
        inputURL: URL,
        outputURL: URL,
        exportSettings: VideoExportSettings = VideoExportSettings(),
        smartFramingSettings: SmartFramingSettings,
        letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth,
        hdrConversionEnabled: Bool = false,
        toneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural,
        progressHandler: @escaping (Double, String) -> Void  // (progress, phaseLabel)
    ) async throws {
        // 既存の出力ファイルを削除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // ── hev1 入力の場合、hvc1 へリマックス（再エンコードなし、品質劣化なし）──
        // AVFoundation の VideoComposition パイプラインは hev1 をデコードできないため、
        // パラメータセットを抽出して正しい hvc1 フォーマット記述を持つ一時ファイルを作成。
        var effectiveInputURL = inputURL
        var tempRemuxURL: URL? = nil
        let inputAssetForCheck = AVAsset(url: inputURL)
        let needsHev1Transcode = await VideoProcessor.isHev1(asset: inputAssetForCheck)
        if needsHev1Transcode {
            NSLog("VideoProcessor: input is hev1; will remux to hvc1 before processing")
            progressHandler(0.0, "Remuxing hev1 → hvc1...")
            let tmpDir = FileManager.default.temporaryDirectory
            let tmpFile = tmpDir.appendingPathComponent(UUID().uuidString + "_hvc1.mov")
            try await remuxHev1ToHvc1(
                inputURL: inputURL,
                outputURL: tmpFile,
                progressHandler: { p in
                    progressHandler(p * 0.3, "Remuxing hev1 → hvc1...")
                }
            )
            effectiveInputURL = tmpFile
            tempRemuxURL = tmpFile
        }
        defer {
            // Clean up temporary remuxed file
            if let tmp = tempRemuxURL {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        
        let asset = AVAsset(url: effectiveInputURL)

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
        // hev1 トランスコードで 0.0〜0.3 を使用済みの場合、残りの進捗帯域を調整
        let hev1Offset: Double = needsHev1Transcode ? 0.3 : 0.0
        let remainingScale: Double = needsHev1Transcode ? 0.7 : 1.0

        var precomputedOffsets: [CGPoint]? = nil
        if smartFramingSettings.enabled {
            let analyzer = SmartFramingAnalyzer()
            precomputedOffsets = try await analyzer.analyze(
                asset: asset,
                videoTrack: videoTrack,
                inputSize: CGSize(width: width, height: height),
                outputSize: CGSize(width: outputWidth, height: outputHeight),
                followFactor: CGFloat(smartFramingSettings.smoothness.followFactor),
                progressHandler: { p in
                    progressHandler(hev1Offset + p * 0.4 * remainingScale, "Analyzing...")
                }
            )
        }
        
        // ── コンポジション作成 + エクスポート（第2パス）──
        let analysisShare = smartFramingSettings.enabled ? 0.4 : 0.0
        let progressOffset = hev1Offset + analysisShare * remainingScale
        let progressScale  = (1.0 - analysisShare) * remainingScale
        
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
            toneMappingMode: toneMappingMode
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
        toneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural
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
        VerticalVideoCompositor.staticToneMappingMode = toneMappingMode
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
        instruction.toneMappingMode = toneMappingMode
        
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
        // SDR output always uses Rec.709 transfer function (sRGB removed as an option)

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
        NSLog("VideoProcessor: encoder path = %@ (codec=%@)",
              useSoftwareVT ? "SoftwareVT (VTCompressionSession)" : "HardwareVT (AVAssetWriter)",
              codec.rawValue)

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
            // SDR input passthrough / HDR→SDR: always use Rec.709 transfer.
            let transferFunction = AVVideoTransferFunction_ITU_R_709_2
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
            NSLog("VideoProcessor: using AVAssetWriter HW encoder path (codec=%@)", codec.rawValue)
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
        let readerStartErr = reader.error?.localizedDescription ?? "none"
        NSLog("VideoProcessor: reader.startReading() status=%d error=%@", reader.status.rawValue, readerStartErr)
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
                                /// Number of leading compressed frames to silently discard
                                /// (used by the VTB warm-up encode to drop the dummy frame).
                                var warmupFramesToDiscard: Int = 0
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
                                    NSLog("VideoProcessor: VT callback error: status=\(status)")
                                    ctx.bufferLock.async { ctx.encodingFinished = true }
                                    return
                                }
                                // Append sampleBuffer to buffer (Swift ARC manages retention)
                                ctx.bufferLock.async {
                                    // VTB warm-up: discard the dummy frame's output
                                    if ctx.warmupFramesToDiscard > 0 {
                                        ctx.warmupFramesToDiscard -= 1
                                        NSLog("VideoProcessor: VT callback discarded warm-up frame")
                                        return
                                    }
                                    ctx.compressedBuffers.append(sbuf)
                                    ctx.compressedBuffersCount += 1
                                }
                            }

                            // Encoder specification: force software-only encoder
                            let encoderSpec: CFDictionary = [
                                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanFalse,
                                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: kCFBooleanFalse
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
                                // For HDR→SDR, the compositor outputs SDR content, so tag the session
                                // with SDR colorimetry (Rec.709/sRGB) to match.
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
                                } else if isHDRInput && hdrConversionRequested {
                                    // HDR→SDR: compositor already tone-mapped to SDR.
                                    // Tell VTCompressionSession the content is Rec.709
                                    // so the encoder initializes its color pipeline for
                                    // SDR from the very first frame.
                                    let sdrTransfer: CFString = kCVImageBufferTransferFunction_ITU_R_709_2 as CFString
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_ColorPrimaries,
                                        value: kCVImageBufferColorPrimaries_ITU_R_709_2 as CFString)
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_TransferFunction,
                                        value: sdrTransfer)
                                    VTSessionSetProperty(compSession,
                                        key: kVTCompressionPropertyKey_YCbCrMatrix,
                                        value: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFString)
                                    NSLog("VideoProcessor: VT color metadata set for HDR→SDR: Rec.709, transfer=\(sdrTransfer)")
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

                            // ── Confirm actual HW/SW encoder selection ──
                            var usingHWValue: CFTypeRef?
                            let hwQueryStatus = VTSessionCopyProperty(
                                compSession,
                                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                allocator: nil,
                                valueOut: &usingHWValue
                            )
                            let usingHW = (hwQueryStatus == noErr) && (usingHWValue as? Bool == true)
                            // queryStatus=-12900 (kVTPropertyNotSupportedErr) means the SW
                            // encoder doesn't implement this property at all → SW confirmed.
                            // queryStatus=0 + usingHW=false → SW confirmed via property.
                            // queryStatus=0 + usingHW=true  → HW encoder was selected.
                            let encoderKind: String
                            if hwQueryStatus == noErr {
                                encoderKind = usingHW ? "HARDWARE" : "SOFTWARE"
                            } else if hwQueryStatus == -12900 {
                                encoderKind = "SOFTWARE (property unsupported = SW encoder)"
                            } else {
                                encoderKind = "UNKNOWN (queryStatus=\(hwQueryStatus))"
                            }
                            NSLog("VideoProcessor: VTCompressionSession created - encoder=%@ (codec=%@)",
                                  encoderKind, codec.rawValue)
                            // VTCompressionSession lazy-initializes its internal color
                            // management pipeline on the first EncodeFrame call. For HDR
                            // content this initialization can produce incorrect gamma on
                            // the first real frame (a well-known VTB bug). We prime the
                            // encoder by feeding a dummy pixel buffer with correct HDR
                            // metadata, flushing it synchronously, and discarding the
                            // compressed output. By the time the real frame 0 arrives the
                            // encoder's color pipeline is fully initialized.
                            if isHDRInput {
                                // IOSurface + Metal 互換: 本番バッファと同じバッキング
                                let warmupAttrs: [String: Any] = [
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferMetalCompatibilityKey as String: true
                                ]
                                var warmupBuf: CVPixelBuffer?
                                CVPixelBufferCreate(
                                    kCFAllocatorDefault,
                                    Int(renderSize.width), Int(renderSize.height),
                                    preferredPixelFormat, warmupAttrs as CFDictionary, &warmupBuf)
                                if let wb = warmupBuf {
                                    // Fill with non-zero data so the encoder exercises
                                    // its full color pipeline (zero data may trigger
                                    // GPU fast-clear optimizations that skip processing).
                                    CVPixelBufferLockBaseAddress(wb, [])
                                    if let addr = CVPixelBufferGetBaseAddress(wb) {
                                        let bpr = CVPixelBufferGetBytesPerRow(wb)
                                        let h = CVPixelBufferGetHeight(wb)
                                        if preferredPixelFormat == kCVPixelFormatType_64RGBAHalf {
                                            let ptr = addr.assumingMemoryBound(to: UInt16.self)
                                            let totalPixels = (bpr / 2) * h
                                            for i in 0..<totalPixels { ptr[i] = 0x4000 } // 2.0 half-float
                                        } else {
                                            memset(addr, 0x80, bpr * h) // mid-gray
                                        }
                                    }
                                    CVPixelBufferUnlockBaseAddress(wb, [])
                                    // Stamp correct color metadata matching what
                                    // the compositor will produce for real frames:
                                    //  • HDR passthrough → HDR metadata
                                    //  • HDR→SDR         → SDR metadata (Rec.709/sRGB)
                                    if hdrConversionRequested {
                                        let sdrTransfer: NSString = kCVImageBufferTransferFunction_ITU_R_709_2 as NSString
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferColorPrimariesKey as CFString,
                                            kCVImageBufferColorPrimaries_ITU_R_709_2 as NSString, .shouldPropagate)
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferTransferFunctionKey as CFString,
                                            sdrTransfer, .shouldPropagate)
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferYCbCrMatrixKey as CFString,
                                            kCVImageBufferYCbCrMatrix_ITU_R_709_2 as NSString, .shouldPropagate)
                                    } else {
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferColorPrimariesKey as CFString,
                                            detectedPrimaries as NSString, .shouldPropagate)
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferTransferFunctionKey as CFString,
                                            detectedTransfer as NSString, .shouldPropagate)
                                        CVBufferSetAttachment(wb,
                                            kCVImageBufferYCbCrMatrixKey as CFString,
                                            detectedMatrix as NSString, .shouldPropagate)
                                    }
                                    context.bufferLock.sync { context.warmupFramesToDiscard = 1 }
                                    let warmupPTS = CMTime(value: -1, timescale: 600)
                                    var warmupFlags: VTEncodeInfoFlags = []
                                    let ws = VTCompressionSessionEncodeFrame(
                                        compSession, imageBuffer: wb,
                                        presentationTimeStamp: warmupPTS,
                                        duration: CMTime(value: 1, timescale: 30),
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &warmupFlags)
                                    if ws == noErr {
                                        VTCompressionSessionCompleteFrames(
                                            compSession,
                                            untilPresentationTimeStamp: warmupPTS)
                                        // Barrier: ensure the callback's async block
                                        // on bufferLock has executed (discard logic).
                                        context.bufferLock.sync { }
                                        NSLog("VideoProcessor: VTB warm-up encode complete (dummy frame discarded)")
                                    } else {
                                        NSLog("VideoProcessor: VTB warm-up encode failed (status=%d), proceeding without warm-up", ws)
                                        context.bufferLock.sync { context.warmupFramesToDiscard = 0 }
                                    }
                                }
                            }

                            // Writer append loop will be created after the passthrough
                            // videoInput is instantiated (after receiving first compressed sample).

                            // Read frames, feed to encoder
                            encodeQueue.async {
                                while true {
                                    // autoreleasepool: CMSampleBuffer / CVPixelBuffer from
                                    // copyNextSampleBuffer() are autoreleased. Without a
                                    // pool, they accumulate for the entire video → multi-GB
                                    // swap usage.
                                    var loopBreak = false
                                    autoreleasepool {
                                    if cancelToken.isCancelled() {
                                        // Best-effort: complete and invalidate local compression session immediately
                                        if let comp = localCompSession {
                                            NSLog("VideoProcessor: encode loop cancellation - completing/invalidate local VT session")
                                            VTCompressionSessionCompleteFrames(comp, untilPresentationTimeStamp: CMTime.invalid)
                                            VTCompressionSessionInvalidate(comp)
                                            // Also remove from shared registry if present
                                            if let ref = localRefconPtr { VTSessionRegistry.shared.remove(refcon: ref) }
                                        }
                                        loopBreak = true
                                        return
                                    }
                                    guard let sample = videoReadQueue.sync(execute: { videoOutput.copyNextSampleBuffer() }) else {
                                        // finished reading
                                        context.readingFinished = true
                                        let readErr = reader.error?.localizedDescription ?? "none"
                                        NSLog("VideoProcessor: copyNextSampleBuffer returned nil; reader.status=%d error=%@", reader.status.rawValue, readErr)
                                        loopBreak = true
                                        return
                                    }
                                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                                        NSLog("VideoProcessor: CMSampleBufferGetImageBuffer returned nil, skipping frame")
                                        return  // continues the while loop
                                    }
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                                    // Prefer using the source sample duration if available
                                    var duration = CMSampleBufferGetDuration(sample)
                                    if duration == CMTime.invalid || duration == CMTime.zero {
                                        duration = videoComposition.frameDuration
                                    }

                                    // ── VTB first-frame gamma workaround (per-frame) ──
                                    // Stamp correct color metadata on every pixel buffer
                                    // before encoding. This ensures VTCompressionSession reads
                                    // consistent colorimetry even if the upstream compositor or
                                    // decoder delivered a buffer with wrong/missing attachments.
                                    //  • HDR passthrough → HDR metadata
                                    //  • HDR→SDR         → SDR metadata (Rec.709/sRGB)
                                    if isHDRInput && !hdrConversionRequested {
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferColorPrimariesKey as CFString,
                                            detectedPrimaries as NSString as CFTypeRef,
                                            .shouldPropagate)
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferTransferFunctionKey as CFString,
                                            detectedTransfer as NSString as CFTypeRef,
                                            .shouldPropagate)
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferYCbCrMatrixKey as CFString,
                                            detectedMatrix as NSString as CFTypeRef,
                                            .shouldPropagate)
                                    } else if isHDRInput && hdrConversionRequested {
                                        let sdrTransfer: NSString = kCVImageBufferTransferFunction_ITU_R_709_2 as NSString
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferColorPrimariesKey as CFString,
                                            kCVImageBufferColorPrimaries_ITU_R_709_2 as NSString as CFTypeRef,
                                            .shouldPropagate)
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferTransferFunctionKey as CFString,
                                            sdrTransfer as CFTypeRef,
                                            .shouldPropagate)
                                        CVBufferSetAttachment(pixelBuffer,
                                            kCVImageBufferYCbCrMatrixKey as CFString,
                                            kCVImageBufferYCbCrMatrix_ITU_R_709_2 as NSString as CFTypeRef,
                                            .shouldPropagate)
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
                                        loopBreak = true
                                        return
                                    }

                                    // progress update (based on input PTS)
                                    let ptsSeconds = pts.seconds
                                    if durationSeconds > 0 {
                                        let p = min(ptsSeconds / durationSeconds, 0.99)
                                        Task { @MainActor in progressHandler(p) }
                                    }

                                    // Throttle if output buffer grows too large.
                                    // Use a tighter threshold and longer sleep to
                                    // prevent multi-GB memory bloat from queued
                                    // compressed sample buffers.
                                    var bufferCount = 0
                                    context.bufferLock.sync {
                                        bufferCount = context.compressedBuffers.count
                                    }
                                    if bufferCount > 30 {
                                        // Back-pressure: wait until writer drains
                                        // the buffer below threshold
                                        while true {
                                            Thread.sleep(forTimeInterval: 0.02)
                                            var current = 0
                                            context.bufferLock.sync {
                                                current = context.compressedBuffers.count
                                            }
                                            if current <= 15 || cancelToken.isCancelled() { break }
                                        }
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
                                    } // end autoreleasepool
                                    if loopBreak { break }
                                }

                                // Finish encoding — synchronous; all VT callbacks will
                                // have fired by the time this returns.
                                VTCompressionSessionCompleteFrames(compSession, untilPresentationTimeStamp: CMTime.invalid)

                                // If the writer was never started during the encode
                                // loop (race: VT callbacks arrived after each
                                // writerStarted check), set it up now with the
                                // freshly available compressed buffers.
                                if !writerStarted {
                                    NSLog("VideoProcessor: writer not started during encode loop; starting late")

                                    // If the reader failed, propagate the error immediately.
                                    if reader.status == .failed {
                                        let failErr = reader.error?.localizedDescription ?? "unknown"
                                        NSLog("VideoProcessor: reader failed: %@", failErr)
                                        writerStarted = true  // unblock audio task
                                        if !context.didResumeContinuation {
                                            context.didResumeContinuation = true
                                            safeResume({ continuation.resume(throwing: reader.error ?? VideoProcessorError.exportFailed) })
                                        }
                                        VTCompressionSessionInvalidate(compSession)
                                        if let ref = localRefconPtr {
                                            VTSessionRegistry.shared.remove(refcon: ref)
                                        }
                                        localRefconPtr = nil
                                        localCompSession = nil
                                        return
                                    }

                                    var firstSbuf: CMSampleBuffer? = nil
                                    context.bufferLock.sync {
                                        if !context.compressedBuffers.isEmpty {
                                            firstSbuf = context.compressedBuffers.first
                                        }
                                    }
                                    if let fs = firstSbuf, let fmt = CMSampleBufferGetFormatDescription(fs) {
                                        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                                        vIn.expectsMediaDataInRealTime = false
                                        NSLog("VideoProcessor: (late) canAdd video: \(writer.canAdd(vIn))")
                                        if writer.canAdd(vIn) {
                                            writer.add(vIn)
                                            videoInput = vIn
                                            if let aIn = audioInput {
                                                if writer.canAdd(aIn) { writer.add(aIn) }
                                            }
                                            writer.startWriting()
                                            writer.startSession(atSourceTime: .zero)
                                            writerStarted = true

                                            // All frames are already compressed; mark finished
                                            // so the drain loop knows to stop after emptying buffers.
                                            context.encodingFinished = true

                                            vIn.requestMediaDataWhenReady(on: appendQueue) {
                                                while vIn.isReadyForMoreMediaData {
                                                    if cancelToken.isCancelled() {
                                                        vIn.markAsFinished()
                                                        context.bufferLock.async {
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
                                                                if !context.didResumeContinuation {
                                                                    context.didResumeContinuation = true
                                                                    safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                                                }
                                                            }
                                                            return
                                                        }
                                                    } else {
                                                        // All buffers drained
                                                        vIn.markAsFinished()
                                                        if !context.didResumeContinuation {
                                                            context.didResumeContinuation = true
                                                            safeResume({ continuation.resume() })
                                                        }
                                                        return
                                                    }
                                                }
                                            }
                                        } else {
                                            // Cannot add input — fail
                                            if !context.didResumeContinuation {
                                                context.didResumeContinuation = true
                                                safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                            }
                                        }
                                    } else {
                                        // No compressed buffers at all (e.g. 0-frame video or VT error)
                                        NSLog("VideoProcessor: (late) no compressed buffers; nothing to write. reader.status=\(reader.status.rawValue) encodedFrames=\(context.compressedBuffersCount)")
                                        writerStarted = true  // unblock audio task
                                        if !context.didResumeContinuation {
                                            context.didResumeContinuation = true
                                            safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                        }
                                    }
                                } else {
                                    // Writer was already started during the encode loop;
                                    // just signal the existing append loop to drain & finish.
                                    context.bufferLock.async {
                                        context.encodingFinished = true
                                    }
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
                                    autoreleasepool {
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
                                    } // end autoreleasepool
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
                            // If writer was never properly started (e.g. reader failed),
                            // do not attempt to use the audio input.
                            if writer.status != .writing {
                                NSLog("VideoProcessor: audio task: writer not in writing state (%d), skipping", writer.status.rawValue)
                                safeResume({ continuation.resume(throwing: VideoProcessorError.exportFailed) })
                                return
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
                    //    Only call markAsFinished if the writer was actually started (status > 0),
                    //    otherwise AVAssetWriterInput throws an exception.
                    if writer.status == .writing {
                        NSLog("VideoProcessor: marking writer inputs finished (onCancel)")
                        videoInput?.markAsFinished()
                        audioInput?.markAsFinished()
                    } else {
                        NSLog("VideoProcessor: skipping markAsFinished (writer.status=\(writer.status.rawValue))")
                    }

                    // 4) Stop reader and cancel writer
                    reader.cancelReading()
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }

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
