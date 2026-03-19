//
//  VerticalVideoCompositor.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

@preconcurrency import AVFoundation
import AppKit
import CoreImage
import CoreText
import CoreVideo
import VideoToolbox
import Vision

class VerticalVideoCompositor: NSObject, AVVideoCompositing {
    // ── Static configuration ──
    // Set by VideoProcessor BEFORE customVideoCompositorClass is assigned.
    // AVFoundation queries sourcePixelBufferAttributes and
    // requiredPixelBufferAttributesForRenderContext immediately after init(),
    // before any startRequest(), so instance variables cannot carry this in time.
    static var staticHDRConversionEnabled: Bool = false
    /// Whether the source video is HDR (used to decide source pixel format)
    static var staticSourceIsHDR: Bool = false
    /// Transfer function string detected from source (e.g. "SMPTE_ST_2084_PQ")
    static var staticTransferFunction: String = ""
    /// Color primaries string detected from source (e.g. "ITU_R_2020")
    static var staticColorPrimaries: String = ""
    /// YCbCr matrix string detected from source
    static var staticYCbCrMatrix: String = ""
    /// Tone mapping mode set by VideoProcessor before compositor instantiation.
    /// Used by primeCIContext() to warm up the exact same CIFilter/kernel chain
    /// that frame 0 will use.
    static var staticToneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural
    /// Input video size (used by primeCIContext to create correctly-sized warm-up
    /// source buffers that exercise the same Metal rendering paths as real frames).
    static var staticInputSize: CGSize = .zero
    /// Whether the output codec is HEVC (H.265). Used to select the correct
    /// output pixel format for HDR passthrough: HEVC's HDR-aware encoding
    /// pipeline applies OETF to float input, so we must output integer format
    /// to avoid double-OETF.
    static var staticIsHEVCOutput: Bool = false
    /// エクスポート開始時に確定したウォーターマーク表示フラグ。
    /// エクスポート中に状態が変わっても一貫した結果になるよう、事前にキャプチャする。
    static var staticShowsWatermark: Bool = false
    private let renderQueue = DispatchQueue(label: "com.verticalconverter.renderqueue")
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext
    // 保留中のリクエストを追跡してキャンセル時に確実に完了させる
    private var pendingRequests: [AVAsynchronousVideoCompositionRequest] = []
    
    // スマートフレーミング用の状態（X方向のオフセット）
    private var smartFramingEnabled: Bool = false
    private var dampingFactor: Double = 0.15
    private var currentOffsetX: CGFloat = 0
    private var frameCount: Int = 0
    private let detectionInterval: Int = 8          // 何フレームごとに検出するか
    private var lastDetectedNormalizedX: CGFloat? = nil
    private var consecutiveMissCount: Int = 0
    private let missThreshold: Int = 5              // 何回連続で未検出なら「いない」と判断するか（8フレーム×5=約40フレーム≒1.3秒）
    private var isFirstSmartFrame: Bool = true      // 初回フレーム判定
    // カットベース: 人物がフレーム中央からこの割合以上ずれたらカット（例: 0.25 = 25%）
    private let cutThreshold: CGFloat = 0.25    /// 事前解析済みオフセット（nil = リアルタイムフォールバック）
    private var currentPrecomputedOffsets: [CGPoint]? = nil    
    // レターボックスモード
    private var letterboxMode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
    // クロップ位置オフセット (0=左/上, 0.5=中央, 1=右/下)
    private var cropPositionX: CGFloat = 0.5
    private var cropPositionY: CGFloat = 0.5
    // HDR -> SDR
    private var hdrConversionEnabled: Bool = false
    private var toneMappingMode: CustomVideoCompositionInstruction.ToneMappingMode = .natural

    // MARK: - Tone Map Kernels
    //
    // Two styles are provided:
    //
    // 1) **Natural** (Reinhard extended + desaturation):
    //    Gentle highlight compression that preserves the original Rec.709/sRGB
    //    color relationships. Highlights roll off smoothly without the S-curve
    //    contrast boost of film stock emulation. The result looks like a
    //    standard broadcast/consumer SDR render of the same scene.
    //
    //    Reinhard extended: t = x / (1 + x) × (1 + x / Lmax²)
    //    Plus a subtle desaturation ramp in the highlights to avoid neon
    //    blowouts that pure per-channel curves produce.
    //
    // 2) **Cinematic** (ACES filmic):
    //    Industry-standard Academy curve with toe contrast lift, mid-tone
    //    saturation, and smooth shoulder. Produces a graded, film-like look.

    // ── Natural: Reinhard extended with highlight desaturation ──
    private static let naturalToneMapKernel: CIColorKernel? = {
        CIColorKernel(source: """
            kernel vec4 naturalToneMap(__sample s) {
                vec3 x = max(s.rgb, vec3(0.0));
                // Reinhard extended (Lmax ~ 6.0 for typical HLG headroom)
                float Lmax2 = 36.0;
                vec3 t = x * (1.0 + x / Lmax2) / (1.0 + x);
                // Subtle highlight desaturation: as luminance rises toward 1.0,
                // blend toward the luminance to tame neon blowouts.
                float lum = dot(t, vec3(0.2126, 0.7152, 0.0722));
                float desat = smoothstep(0.5, 1.0, lum) * 0.4;
                vec3 result = mix(t, vec3(lum), desat);
                return vec4(clamp(result, 0.0, 1.0), s.a);
            }
        """)
    }()

    // ── Cinematic: ACES filmic ──
    // CIContext's color-space conversion alone does NOT perform tone mapping;
    // it simply clips linear values > 1.0 when rendering to an SDR color space.
    // This destroys the relative brightness relationships of HDR content and
    // produces a washed-out / pale image.
    //
    // The ACES filmic curve compresses the full HDR range into [0, 1] with
    // natural highlight roll-off and good mid-tone / saturation preservation.
    //
    //   f(x) = clamp((x·(2.51x + 0.03)) / (x·(2.43x + 0.59) + 0.14), 0, 1)
    //
    // At reference white (x ≈ 1.0) → ~0.80 (maps to ~0.91 sRGB after gamma).
    // At 5× reference white         → ~0.99 (smooth roll-off, no hard clip).
    private static let acesToneMapKernel: CIColorKernel? = {
        CIColorKernel(source: """
            kernel vec4 acesToneMap(__sample s) {
                vec3 x = max(s.rgb, vec3(0.0));
                float a = 2.51;
                float b = 0.03;
                float c = 2.43;
                float d = 0.59;
                float e = 0.14;
                vec3 m = clamp((x * (a * x + b)) / (x * (c * x + d) + e),
                               0.0, 1.0);
                return vec4(m, s.a);
            }
        """)
    }()

    /// Apply natural (Reinhard) tone mapping to a CIImage.
    private func applyNaturalToneMap(to image: CIImage) -> CIImage {
        guard let kernel = Self.naturalToneMapKernel else {
            NSLog("VerticalVideoCompositor: Natural tone-map kernel unavailable")
            return image
        }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    /// Apply ACES filmic tone mapping to a CIImage (cinematic fallback).
    private func applyACESToneMap(to image: CIImage) -> CIImage {
        guard let kernel = Self.acesToneMapKernel else {
            NSLog("VerticalVideoCompositor: ACES tone-map kernel unavailable")
            return image
        }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    /// Apply HDR → SDR tone mapping based on the selected `toneMappingMode`.
    ///
    /// - **Natural** (default): Reinhard extended + highlight desaturation.
    ///   On macOS 15+ also tries `CIToneMapHeadroom` which produces an
    ///   Apple-standard neutral result. Falls back to Reinhard kernel.
    ///
    /// - **Cinematic**: ACES filmic curve for a graded, film-like look.
    ///   On macOS 15+ uses `CIToneMapHeadroom` as primary, with ACES
    ///   kernel as legacy fallback on macOS 14 and below.
    private func applyToneMapping(to image: CIImage) -> CIImage {
        let tLower = VerticalVideoCompositor.staticTransferFunction.lowercased()
        let isPQ = tLower.contains("pq") || tLower.contains("2084")

        // macOS 15+ / iOS 18+: use Apple's CIToneMapHeadroom for both modes.
        // BT.2390-compliant tone mapping with proper gamut mapping built-in.
        if #available(macOS 15.0, iOS 18.0, *) {
            let sourceHeadroom: Float = isPQ ? 16.0 : 4.0
            return image.applyingFilter("CIToneMapHeadroom", parameters: [
                "inputSourceHeadroom": sourceHeadroom,
                "inputTargetHeadroom": Float(1.0)
            ])
        }

        // macOS 14 and below: fall back to custom CIColorKernel
        switch toneMappingMode {
        case .cinematic:
            return applyACESToneMap(to: image)
        case .natural:
            return applyNaturalToneMap(to: image)
        }
    }

    override init() {
        // Choose the CIContext working color space based on the pipeline:
        //
        // HDR passthrough:
        //   DISABLE color management entirely (NSNull). CIContext treats
        //   all pixel values as raw generic components. No OETF inversion,
        //   no gamut conversion. The OETF-encoded HLG/PQ values pass
        //   through geometric transforms and blur as-is, then go directly
        //   to the encoder. Combined with videoComposition.colorPrimaries
        //   / colorTransferFunction / colorYCbCrMatrix being set to the
        //   source's native HDR properties, AVFoundation no longer applies
        //   implicit BT.709 color conversion on the compositor output.
        //
        // HDR→SDR:
        //   Use extendedLinearITUR_2020 to keep BT.2020 content in native
        //   gamut during processing. CIToneMapHeadroom operates on linear
        //   BT.2020 values. Final BT.2020→Rec.709 gamut conversion happens
        //   at the render step.
        //
        // SDR: extendedLinearSRGB (standard).
        let isHDRPassthrough = VerticalVideoCompositor.staticSourceIsHDR
            && !VerticalVideoCompositor.staticHDRConversionEnabled
        if isHDRPassthrough {
            ciContext = CIContext(options: [.workingColorSpace: NSNull()])
        } else if VerticalVideoCompositor.staticSourceIsHDR {
            let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            ciContext = CIContext(options: [.workingColorSpace: workingCS])
        } else {
            let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            ciContext = CIContext(options: [.workingColorSpace: workingCS])
        }
        super.init()
    }
    
    var sourcePixelBufferAttributes: [String : Any]? {
        // For HDR source (passthrough OR →SDR), always request 64RGBAHalf
        // to preserve the full dynamic range for compositing.
        // For SDR, 32BGRA is sufficient and more efficient.
        // Using a single format ensures AVFoundation delivers a consistent
        // pixel format across ALL frames (including frame 0).
        if VerticalVideoCompositor.staticSourceIsHDR {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]
        } else {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]
        }
    }
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] {
        // AVFoundation queries this ONCE at compositor init, before any frame
        // arrives. We read the static properties (set by VideoProcessor before
        // the compositor is created) so the render buffer pool gets the correct
        // format.
        //
        // CRITICAL: This format MUST match the reader output's
        // preferredPixelFormat set in VideoProcessor.exportVideo().
        // Any mismatch forces AVFoundation to perform implicit format
        // conversion between compositor output and reader output, which may
        // initialize lazily and cause frame-0 gamma/color inconsistency.
        //
        //  • HDR passthrough (non-HEVC) → 64RGBAHalf (preserve HDR values)
        //  • HDR passthrough (HEVC)     → 32BGRA (integer prevents double-OETF)
        //  • HDR→SDR                    → 32BGRA (SDR output)
        //  • SDR                        → 32BGRA (SDR output)
        //
        // HEVC encoders (both SW and HW) interpret 64RGBAHalf as scene-linear
        // and apply OETF when TransferFunction is HLG/PQ. Since the values
        // from NSNull CIContext are already OETF-encoded, this causes double-
        // OETF and produces dark/SDR-tone output. Using 32BGRA (integer)
        // avoids this because encoders treat integer data as display-referred.
        // H264 and ProRes do not have HDR-aware pipelines, so float is fine.
        let isHDRPassthrough = VerticalVideoCompositor.staticSourceIsHDR
            && !VerticalVideoCompositor.staticHDRConversionEnabled
        if isHDRPassthrough && !VerticalVideoCompositor.staticIsHEVCOutput {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]
        } else {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]
        }
    }
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            renderContext = newRenderContext
            primeCIContext(renderSize: newRenderContext.size)
        }
    }

    /// Production `ciContext` を frame 0 到着前に完全に初期化する。
    ///
    /// WarmupContext 分離では不十分だった理由：
    /// `CIContext` の Metal シェーダーキャッシュは同じ `MTLDevice` を共有するので
    /// 別 Context でコンパイルされたシェーダー自体は共有される。
    /// しかし **Metal コマンドバッファ・テクスチャキャッシュ・IOSurface backing** など
    /// ciContext 固有の内部状態は共有されない。
    /// これが frame 0 でのみ色変換の挙動が変わる直接原因。
    ///
    /// 解決策：本番 ciContext で本番 composeFrame を完全に通す。
    /// dummy バッファへの書き込みなので出力は捨てる。
    ///
    /// CRITICAL (IOSurface):
    /// AVFoundation のデコーダとレンダーコンテキストのピクセルバッファプールは
    /// IOSurface/Metal 互換のバッファを返す。CIContext は IOSurface 有無で
    /// Metal テクスチャの生成パスが異なるため、prime でも IOSurface 付きの
    /// バッファを使う必要がある。これがないと frame 0 で別の Metal パスが走り
    /// ガンマが狂う。
    private func primeCIContext(renderSize: CGSize) {
        let isHDRPassthrough = VerticalVideoCompositor.staticSourceIsHDR
            && !VerticalVideoCompositor.staticHDRConversionEnabled
        // Match requiredPixelBufferAttributesForRenderContext format:
        // HEVC HDR passthrough → 32BGRA (integer to avoid double-OETF)
        // Non-HEVC HDR passthrough → 64RGBAHalf
        let outputFormat: OSType
        if isHDRPassthrough && !VerticalVideoCompositor.staticIsHEVCOutput {
            outputFormat = kCVPixelFormatType_64RGBAHalf
        } else {
            outputFormat = kCVPixelFormatType_32BGRA
        }
        let srcFormat: OSType = VerticalVideoCompositor.staticSourceIsHDR
            ? kCVPixelFormatType_64RGBAHalf
            : kCVPixelFormatType_32BGRA

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        // IOSurface + Metal 互換属性。AVFoundation の本番バッファと同じ
        // バッキングを使うことで CIContext 内部の Metal テクスチャ生成パスを
        // 本番と一致させる。
        let ioSurfaceAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        // 出力バッファ: renderContext のプールから取得（本番と同一プロパティ）。
        // プール未準備時は IOSurface 付きで自前生成。
        let outBuf: CVPixelBuffer
        if let poolBuf = renderContext?.newPixelBuffer() {
            outBuf = poolBuf
        } else {
            var temp: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, outputFormat,
                                ioSurfaceAttrs as CFDictionary, &temp)
            guard let t = temp else { return }
            outBuf = t
        }

        // ソースバッファ: IOSurface + Metal 互換で生成
        // CRITICAL: Use staticInputSize (actual input video dimensions) instead
        // of renderSize. CIContext / Metal internally selects different texture
        // allocation and shader paths depending on the source image size.
        // A 1080×1920 (output-sized) warm-up source exercises a different Metal
        // path than the real 3840×2160 (or 1920×1080) source, which caused
        // frame 0 to render with a different gamma/color because the lazy Metal
        // initialisation happened on two different code paths.
        let srcW = VerticalVideoCompositor.staticInputSize.width > 0
            ? Int(VerticalVideoCompositor.staticInputSize.width) : width
        let srcH = VerticalVideoCompositor.staticInputSize.height > 0
            ? Int(VerticalVideoCompositor.staticInputSize.height) : height
        var dummySrc: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH, srcFormat,
                            ioSurfaceAttrs as CFDictionary, &dummySrc)
        guard let srcBuf = dummySrc else { return }

        // ソースバッファに非ゼロのピクセル値を書き込む。
        // 全ゼロデータは Metal の fast-clear 最適化により実際のシェーダー実行が
        // スキップされる可能性がある。HDR ソースには half-float 2.0 (0x4000) を
        // 書いてトーンマッピングカーブの圧縮領域を実際に通す。
        CVPixelBufferLockBaseAddress(srcBuf, [])
        if let baseAddr = CVPixelBufferGetBaseAddress(srcBuf) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(srcBuf)
            if srcFormat == kCVPixelFormatType_64RGBAHalf {
                // Half-float 2.0 = 0x4000 — typical HLG bright pixel
                for row in 0..<srcH {
                    let rowPtr = baseAddr.advanced(by: row * bytesPerRow)
                        .assumingMemoryBound(to: UInt16.self)
                    for i in 0..<(srcW * 4) {
                        rowPtr[i] = 0x4000
                    }
                }
            } else {
                // 32BGRA: mid-gray (128)
                memset(baseAddr, 0x80, bytesPerRow * srcH)
            }
        }
        CVPixelBufferUnlockBaseAddress(srcBuf, [])

        // instance variables のバックアップ（prime 後に復元）
        let savedHDR = hdrConversionEnabled
        let savedSmart = smartFramingEnabled
        let savedToneMap = toneMappingMode

        // prime 時は本番の設定を使う（static から派生）
        hdrConversionEnabled = VerticalVideoCompositor.staticHDRConversionEnabled
        toneMappingMode = VerticalVideoCompositor.staticToneMappingMode
        smartFramingEnabled = false   // letterbox パスを強制（Vision 不要）

        // 本番 ciContext で本番 composeFrame を 2 回完全に通す。
        // 1 回目: Metal シェーダーコンパイル + パイプラインステート生成 +
        //         テクスチャキャッシュ初期化
        // 2 回目: コマンドバッファ・IOSurface バッキングの定常状態を確立。
        //         1 回だけでは lazy-init が完了しないケースがある。
        for _ in 0..<2 {
            composeFrame(
                sourcePixelBuffer: srcBuf,
                outputPixelBuffer: outBuf,
                renderSize: renderSize
            )
        }

        // instance variables を復元
        hdrConversionEnabled = savedHDR
        smartFramingEnabled = savedSmart
        toneMappingMode = savedToneMap
        // outBuf / srcBuf の内容は破棄される
    }

    // MARK: - Source color space resolution

    /// Return the correct CGColorSpace for HDR source buffers.
    ///
    /// The correct color space depends on whether we are doing HDR passthrough
    /// or HDR→SDR conversion:
    ///
    /// **HDR→SDR** (`forToneMapping: true`):
    ///   Use the non-linear `itur_2100_HLG` / `itur_2100_PQ` color space.
    ///   AVFoundation’s decoder outputs 64RGBAHalf with OETF-encoded values.
    ///   Tagging with the correct non-linear CS makes CIContext apply the
    ///   inverse OETF during processing, producing true linear values in the
    ///   working space. Tone mapping then compresses these to [0, 1].
    ///
    /// **HDR passthrough** (`forToneMapping: false`):
    ///   Use `extendedLinearITUR_2020`. This tells CIContext the values are
    ///   already linear, so it skips the OETF→linear→OETF round-trip.
    ///   The HLG OOTF (system gamma ~1.2) applied during linearization
    ///   combined with the sRGB working-space conversion does not perfectly
    ///   round-trip, causing systematic darkening of the entire image.
    ///   Since passthrough only needs geometric transforms (scale, translate,
    ///   crop) and a background blur, skipping linearization is safe and
    ///   avoids the brightness loss.
    private static func resolvedHDRSourceColorSpace(forToneMapping: Bool) -> CGColorSpace {
        let tLower = staticTransferFunction.lowercased()
        let pLower = staticColorPrimaries.lowercased()

        if forToneMapping {
            // Non-linear: CIContext will apply inverse OETF for proper tone mapping.
            if tLower.contains("hlg") {
                if pLower.contains("2020") {
                    if let cs = CGColorSpace(name: CGColorSpace.itur_2100_HLG) {
                        return cs
                    }
                }
            } else if tLower.contains("pq") || tLower.contains("2084") {
                if pLower.contains("2020") {
                    if let cs = CGColorSpace(name: CGColorSpace.itur_2100_PQ) {
                        return cs
                    }
                }
            }
        }

        // Passthrough or fallback: extended linear – no OETF round-trip
        if pLower.contains("2020") {
            return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        } else if pLower.contains("p3") {
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        }
        return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            // autoreleasepool: CIImage / CIContext render intermediates and
            // CVPixelBuffer wrappers are autoreleased. Without a pool each
            // frame's temporaries accumulate until the queue drains, which
            // for a long video means gigabytes of unreleased memory.
            autoreleasepool {
            guard let self = self else {
                NSLog("VerticalVideoCompositor: FAILED - self is nil (compositor deallocated)")
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "self is nil"]
                ))
                return
            }

            // 追跡用に追加
            self.pendingRequests.append(asyncVideoCompositionRequest)
            let removePending: () -> Void = {
                if let idx = self.pendingRequests.firstIndex(where: { $0 === asyncVideoCompositionRequest }) {
                    self.pendingRequests.remove(at: idx)
                }
            }
            
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? CustomVideoCompositionInstruction else {
                NSLog("VerticalVideoCompositor: FAILED - instruction cast failed (type=%@)", String(describing: type(of: asyncVideoCompositionRequest.videoCompositionInstruction)))
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "instruction cast failed"]
                ))
                removePending()
                return
            }
            
            guard let layerInstruction = instruction.layerInstructions.first as? AVVideoCompositionLayerInstruction else {
                NSLog("VerticalVideoCompositor: FAILED - layerInstruction cast failed (count=%d)", instruction.layerInstructions.count)
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "layerInstruction cast failed"]
                ))
                removePending()
                return
            }
            
            // スマートフレーミング設定を取得
            self.smartFramingEnabled = instruction.smartFramingEnabled
            self.dampingFactor = instruction.dampingFactor
            self.currentPrecomputedOffsets = instruction.precomputedOffsets
            self.letterboxMode = instruction.letterboxMode
            self.cropPositionX = instruction.cropPositionX
            self.cropPositionY = instruction.cropPositionY
            // HDR settings
            let hdrEnabled = instruction.hdrConversionEnabled
            // store in local vars for composeFrame
            self.hdrConversionEnabled = hdrEnabled
            self.toneMappingMode = instruction.toneMappingMode

            guard let sourcePixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: layerInstruction.trackID) else {
                NSLog("VerticalVideoCompositor: FAILED - sourceFrame is nil for trackID=%d, requiredSourceTrackIDs=%@, sourceTrackIDs=%@",
                      layerInstruction.trackID,
                      String(describing: asyncVideoCompositionRequest.videoCompositionInstruction.requiredSourceTrackIDs),
                      String(describing: asyncVideoCompositionRequest.sourceTrackIDs))
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "sourceFrame nil for trackID=\(layerInstruction.trackID)"]
                ))
                removePending()
                return
            }

            // 出力バッファを作成
            guard let renderContext = self.renderContext,
                  let outputPixelBuffer = renderContext.newPixelBuffer() else {
                NSLog("VerticalVideoCompositor: FAILED - renderContext=%@, newPixelBuffer=nil", String(describing: self.renderContext))
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "renderContext or outputPixelBuffer nil"]
                ))
                removePending()
                return
            }
            
            // フレームを合成
            self.composeFrame(
                sourcePixelBuffer: sourcePixelBuffer,
                outputPixelBuffer: outputPixelBuffer,
                renderSize: renderContext.size
            )
            
            asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputPixelBuffer)
            removePending()
            } // end autoreleasepool
        }
    }
    
    private func composeFrame(
        sourcePixelBuffer: CVPixelBuffer,
        outputPixelBuffer: CVPixelBuffer,
        renderSize: CGSize
    ) {
        // ── Source color space determination ──
        // CRITICAL: For HDR sources, ALWAYS use the color space resolved from
        // static metadata (track format description). NEVER rely on per-frame
        // CVImageBufferGetColorSpace() because some decoders do NOT attach
        // correct color metadata to frame 0. This inconsistency (frame 0 gets
        // Rec.709/nil, frame 1+ gets BT.2020) is the root cause of the
        // "first frame gamma mismatch" bug.
        let sourceColorSpace: CGColorSpace?
        let sourceImage: CIImage
        let isHDRPassthrough = VerticalVideoCompositor.staticSourceIsHDR
            && !hdrConversionEnabled

        if isHDRPassthrough {
            // HDR passthrough: CIContext has color management DISABLED (NSNull).
            // Do NOT tag the source with any color space — CIContext will treat
            // all values as raw generic components. The OETF-encoded HLG/PQ
            // values pass through transforms and blur unchanged.
            sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
            sourceColorSpace = nil
        } else if VerticalVideoCompositor.staticSourceIsHDR {
            // HDR→SDR: tag with non-linear CS for proper OETF inversion
            let cs = Self.resolvedHDRSourceColorSpace(forToneMapping: true)
            sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer,
                                  options: [.colorSpace: cs])
            sourceColorSpace = cs
        } else {
            // SDR: Use sRGB consistently for ALL frames.
            // DO NOT use per-buffer CVImageBufferGetColorSpace — frame 0 may
            // return nil (falling back to itur_709), while frame 1+ may return
            // sRGB. itur_709 and sRGB have subtly different gamma curves (pure
            // power vs piecewise-linear), so mixing them through the
            // extendedLinearSRGB working space produces a visible contrast
            // difference on frame 0.
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer,
                                  options: [.colorSpace: cs])
            sourceColorSpace = cs
        }
        let sourceSize = sourceImage.extent.size
        let outputRect = CGRect(origin: .zero, size: renderSize)

        let finalImage: CIImage

        if smartFramingEnabled {
            // スマートフレーミングON: 縦いっぱいにズームして人物のX位置に合わせて横パン
            finalImage = makeSmartFramedImage(
                sourceImage: sourceImage, sourceSize: sourceSize,
                sourcePixelBuffer: sourcePixelBuffer,
                renderSize: renderSize, outputRect: outputRect
            )
        } else {
            // スマートフレーミングOFF: 横幅に合わせてレターボックス + ブラー背景
            finalImage = makeLetterboxImage(
                sourceImage: sourceImage, sourceSize: sourceSize,
                renderSize: renderSize, outputRect: outputRect,
                mode: self.letterboxMode
            )
        }

        let imageToRender: CIImage
        if Self.staticShowsWatermark {
            imageToRender = Self.overlayWatermark(on: finalImage, renderSize: renderSize)
        } else {
            imageToRender = finalImage
        }

        if hdrConversionEnabled {
            // HDR->SDR: CoreImage color space conversion handles the EOTF mapping
            // during the render call below. Mark output buffer with the correct
            // transfer function (always Rec.709 for SDR output).
            let primariesStr = NSString(string: "ITU_R_709_2")
            let matrixStr    = NSString(string: "ITU_R_709_2")
            let transferStr: NSString = kCVImageBufferTransferFunction_ITU_R_709_2 as NSString
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferColorPrimariesKey as CFString, primariesStr, .shouldPropagate)
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferTransferFunctionKey as CFString, transferStr, .shouldPropagate)
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferYCbCrMatrixKey as CFString, matrixStr, .shouldPropagate)
        } else {
            // Preserve HDR/SDR metadata on the output buffer.
            //
            // CRITICAL (VTB first-frame gamma workaround):
            // For HDR sources, ALWAYS set primaries / transfer function /
            // YCbCr matrix from track-level static metadata. NEVER copy
            // these three keys from the source pixel buffer's per-frame
            // attachments, because some VT decoders deliver frame 0 with
            // INCORRECT colorimetry (e.g. Rec.709 instead of BT.2020/PQ).
            // The previous code only fell back to static metadata when the
            // transfer function was *missing*, but the real-world failure
            // mode is *wrong* values being present — so the fallback never
            // triggered and the wrong metadata propagated to VTB encoder,
            // causing it to interpret frame 0 under a different EOTF.
            //
            // Optional per-frame keys (mastering display colour volume,
            // content light level) are safe to copy from the source because
            // they do not influence the EOTF / gamma interpretation.
            func makeCFCompatible(_ any: Any) -> CFTypeRef? {
                if let ns = any as? NSString { return ns }
                if let s = any as? String { return NSString(string: s) }
                if let num = any as? NSNumber { return num }
                if let dict = any as? NSDictionary { return dict }
                if let dict = any as? [AnyHashable: Any] { return dict as NSDictionary }
                if let arr = any as? NSArray { return arr }
                if let arr = any as? [Any] { return arr as NSArray }
                return NSString(string: String(describing: any))
            }

            if VerticalVideoCompositor.staticSourceIsHDR {
                // ── HDR passthrough: stamp all three colorimetry keys ──
                // The output buffer format is now integer (32BGRA) for HEVC
                // output, so stamping TransferFunction is safe — HEVC encoders
                // treat integer data as display-referred and do NOT apply OETF.
                // For non-HEVC (64RGBAHalf), the encoder doesn't have an HDR
                // pipeline so the stamp is also safe.
                let tf = VerticalVideoCompositor.staticTransferFunction
                let pr = VerticalVideoCompositor.staticColorPrimaries
                let mx = VerticalVideoCompositor.staticYCbCrMatrix
                if !tf.isEmpty {
                    CVBufferSetAttachment(outputPixelBuffer,
                        kCVImageBufferTransferFunctionKey as CFString,
                        tf as NSString, .shouldPropagate)
                }
                if !pr.isEmpty {
                    CVBufferSetAttachment(outputPixelBuffer,
                        kCVImageBufferColorPrimariesKey as CFString,
                        pr as NSString, .shouldPropagate)
                }
                if !mx.isEmpty {
                    CVBufferSetAttachment(outputPixelBuffer,
                        kCVImageBufferYCbCrMatrixKey as CFString,
                        mx as NSString, .shouldPropagate)
                }
                // Copy optional mastering display + content light level from source
                let optionalKeys: [CFString] = [
                    kCVImageBufferMasteringDisplayColorVolumeKey as CFString,
                    kCVImageBufferContentLightLevelInfoKey as CFString
                ]
                for key in optionalKeys {
                    if let val = CVBufferGetAttachment(sourcePixelBuffer, key, nil) {
                        if let cf = makeCFCompatible(val) {
                            CVBufferSetAttachment(outputPixelBuffer, key, cf, .shouldPropagate)
                        }
                    }
                }
            } else {
                // ── SDR: copy color attachments from source buffer ──
                let attachKeys: [CFString] = [
                    kCVImageBufferColorPrimariesKey as CFString,
                    kCVImageBufferTransferFunctionKey as CFString,
                    kCVImageBufferYCbCrMatrixKey as CFString
                ]
                for key in attachKeys {
                    if let val = CVBufferGetAttachment(sourcePixelBuffer, key, nil) {
                        if let cf = makeCFCompatible(val) {
                            CVBufferSetAttachment(outputPixelBuffer, key, cf, .shouldPropagate)
                        }
                    }
                }
            }
        }

        // ── Render ──
        if hdrConversionEnabled {
            // HDR→SDR: Apply tone mapping BEFORE the color-space conversion.
            // Without this step CIContext simply clips linear values > 1.0,
            // destroying brightness relationships and producing a washed-out
            // / pale image. The source CIImage was created with the correct
            // non-linear HLG/PQ color space, so CIContext has already applied
            // the inverse OETF → the working-space values are true linear with
            // HDR highlights > 1.0. Tone mapping compresses them to [0, 1].
            let toneMapped = applyToneMapping(to: imageToRender)

            // Always render to Rec.709 for SDR output
            let targetCS: CGColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
            ciContext.render(toneMapped, to: outputPixelBuffer, bounds: outputRect, colorSpace: targetCS)
        } else if VerticalVideoCompositor.staticSourceIsHDR {
            // HDR passthrough: CIContext has color management disabled (NSNull).
            // Render with nil colorSpace → no color conversion at all.
            // Raw OETF-encoded values pass through to the output buffer.
            ciContext.render(imageToRender, to: outputPixelBuffer, bounds: outputRect, colorSpace: nil)
        } else {
            // SDR passthrough: render to sRGB (fixed, consistent across all frames).
            ciContext.render(imageToRender, to: outputPixelBuffer, bounds: outputRect, colorSpace: sourceColorSpace)
        }
    }

    // MARK: - レターボックス

    private func makeLetterboxImage(
        sourceImage: CIImage,
        sourceSize: CGSize,
        renderSize: CGSize,
        outputRect: CGRect,
        mode: CustomVideoCompositionInstruction.LetterboxMode = .fitWidth
    ) -> CIImage {
        // デフォルト: 既存の幅に合わせるモード
        if mode == .fitWidth {
            let scale = renderSize.width / sourceSize.width
            let scaledWidth = sourceSize.width * scale
            let scaledHeight = sourceSize.height * scale
            let mainX = (renderSize.width - scaledWidth) / 2
            let mainY = (renderSize.height - scaledHeight) * cropPositionY  // 垂直位置オフセット適用

            let mainVideo = sourceImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: mainX, y: mainY))
                .cropped(to: outputRect)  // extent を outputRect に揃える

            let bgScale = renderSize.height / sourceSize.height
            let bgWidth = sourceSize.width * bgScale
            let bgX = (renderSize.width - bgWidth) / 2
            let blurredBg = sourceImage
                .transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
                .transformed(by: CGAffineTransform(translationX: bgX, y: 0))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 40)
                .cropped(to: outputRect)

            return mainVideo.composited(over: blurredBg)
        }

        // 高さに合わせるモード（左右をクロップ・背景不要）
        if mode == .fitHeight {
            let scale = renderSize.height / sourceSize.height
            let scaledWidth = sourceSize.width * scale
            let mainX = (renderSize.width - scaledWidth) * cropPositionX  // 水平位置オフセット適用

            let mainVideo = sourceImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: mainX, y: 0))
                .cropped(to: outputRect)

            return mainVideo
        }

        // centerSquare / centerPortrait4x3 / centerPortrait3x4: 中央を指定アスペクトでクロップ
        let targetAspect: CGFloat
        switch mode {
        case .centerSquare:
            targetAspect = 1.0
        case .centerPortrait4x3:
            targetAspect = 3.0 / 4.0
        case .centerPortrait3x4:
            targetAspect = 4.0 / 3.0
        default:
            targetAspect = 1.0
        }

        var cropRect = CGRect(origin: .zero, size: sourceSize)
        let sourceAspect = sourceSize.width / sourceSize.height
        if sourceAspect > targetAspect {
            // 元が横長 -> 横をトリミング
            let cropW = sourceSize.height * targetAspect
            let cropX = (sourceSize.width - cropW) * cropPositionX  // 水平位置オフセット適用
            cropRect = CGRect(x: cropX, y: 0, width: cropW, height: sourceSize.height)
        } else {
            // 元が縦長または同等 -> 縦をトリミング
            let cropH = sourceSize.width / targetAspect
            let cropY = (sourceSize.height - cropH) * cropPositionY  // 垂直位置オフセット適用
            cropRect = CGRect(x: 0, y: cropY, width: sourceSize.width, height: cropH)
        }

        let cropped = sourceImage.cropped(to: cropRect)

        // メイン映像は幅に合わせてスケール（左右を若干トリミングして中央を強調）
        let scale = renderSize.width / cropRect.width
        let scaledHeight = cropRect.height * scale
        let mainY = (renderSize.height - scaledHeight) * cropPositionY  // 垂直位置オフセット適用

        // cropped の座標原点が cropRect.origin になるため、変換時に原点オフセットを打ち消す
        let translateX = -cropRect.origin.x * scale + (renderSize.width - cropRect.width * scale) / 2
        let translateY = mainY - cropRect.origin.y * scale

        let mainVideo = cropped
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: translateX, y: translateY))
            .cropped(to: outputRect)

        // 背景は元映像を高さに合わせて拡大してブラー
        let bgScale = renderSize.height / sourceSize.height
        let bgWidth = sourceSize.width * bgScale
        let bgX = (renderSize.width - bgWidth) / 2
        let blurredBg = sourceImage
            .transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
            .transformed(by: CGAffineTransform(translationX: bgX, y: 0))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .cropped(to: outputRect)

        return mainVideo.composited(over: blurredBg)
    }

    // MARK: - スマートフレーミング

    private func makeSmartFramedImage(
        sourceImage: CIImage,
        sourceSize: CGSize,
        sourcePixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
        outputRect: CGRect
    ) -> CIImage {
        // 縦いっぱいにズームするスケール（Yパン余白確保のため yZoomFactor 倉でズームイン）
        let zoomFactor = SmartFramingAnalyzer.yZoomFactor
        let scale = renderSize.height / sourceSize.height * zoomFactor
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let minOffsetX = -(scaledWidth - renderSize.width)
        let centerOffsetY = (renderSize.height - scaledHeight) / 2   // Y方向の中央初期値

        frameCount += 1

        // ── 事前解析済みオフセットがあれば使う（2パスモード）──
        if let offsets = currentPrecomputedOffsets, !offsets.isEmpty {
            let idx = min(frameCount - 1, offsets.count - 1)
            let offset = offsets[max(0, idx)]
            return sourceImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
                .cropped(to: outputRect)
        }

        // ── フォールバック: リアルタイム Vision（1パスモード）──
        if frameCount % detectionInterval == 0 || frameCount == 1 {
            detectPersonNormalizedX(in: sourcePixelBuffer)
        }

        // 初回フレーム: 中央に初期化（Vision 未検出のまま走る場合も安全な中央値を確定させる）
        if isFirstSmartFrame {
            isFirstSmartFrame = false
            // True center: half of the negative total excess width.
            currentOffsetX = -(scaledWidth - renderSize.width) / 2
            if lastDetectedNormalizedX == nil {
                // No person detected yet — stay dead-center rather than drifting.
                currentOffsetX = -(scaledWidth - renderSize.width) / 2
            }
        }

        // カットベース: 人物がコンフォートゾーンを外れたときだけスナップ
        if let normalizedX = lastDetectedNormalizedX {
            let personX = normalizedX * scaledWidth
            let personInFrame = personX + currentOffsetX
            let centerDelta = personInFrame - renderSize.width / 2
            if abs(centerDelta) > renderSize.width * cutThreshold {
                let desired = renderSize.width / 2 - personX
                currentOffsetX = max(minOffsetX, min(0, desired))
            }
        }

        return sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: currentOffsetX, y: centerOffsetY))
            .cropped(to: outputRect)
    }
    
    // MARK: - 人物検出（Visionは間引いて実行）

    private func detectPersonNormalizedX(in pixelBuffer: CVPixelBuffer) {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest]) } catch { return }

        var allPersonsX: [CGFloat] = []

        // 人体ポーズ検出（優先）
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            for observation in bodyResults {
                if let points = try? observation.recognizedPoints(.all) {
                    let upperPoints = [
                        points[.neck], points[.leftShoulder],
                        points[.rightShoulder], points[.nose]
                    ].compactMap { $0 }.filter { $0.confidence > 0.3 }
                    if !upperPoints.isEmpty {
                        let avgX = upperPoints.reduce(0.0) { $0 + $1.location.x } / CGFloat(upperPoints.count)
                        allPersonsX.append(avgX)
                    }
                }
            }
        }

        // 顔検出（フォールバック）
        if allPersonsX.isEmpty, let faceResults = faceRequest.results, !faceResults.isEmpty {
            for face in faceResults {
                allPersonsX.append(face.boundingBox.midX)
            }
        }

        guard !allPersonsX.isEmpty else {
            // 未検出: ミスカウンター増加。閾値を超えたら lastDetected をリセット
            consecutiveMissCount += 1
            if consecutiveMissCount >= missThreshold {
                lastDetectedNormalizedX = nil
            }
            return
        }

        // 検出成功: ミスカウンターをリセット
        consecutiveMissCount = 0
        let detectedX: CGFloat
        if allPersonsX.count == 1 {
            detectedX = allPersonsX[0]
        } else {
            // 複数人: 全員を包むバウンディングボックスの中心を使用
            let minX = allPersonsX.min()!
            let maxX = allPersonsX.max()!
            detectedX = (minX + maxX) / 2
        }
        // Visionのノイズを抑えるため検出値自体もローパスフィルター（新値50%ブレンド）
        if let existing = lastDetectedNormalizedX {
            lastDetectedNormalizedX = existing + (detectedX - existing) * 0.5
        } else {
            lastDetectedNormalizedX = detectedX
        }
    }

    // MARK: - Watermark (Demo edition)

    /// デモ版用：斜めに繰り返す半透明ウォーターマークを合成する
    private static func overlayWatermark(on image: CIImage, renderSize: CGSize) -> CIImage {
        let text = "DEMO"
        let fontSize: CGFloat = renderSize.height * 0.06
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ]
        let nsStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(nsStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // タイル間のスペース
        let tileW = bounds.width + fontSize * 2.5
        let tileH = bounds.height + fontSize * 4.0

        // NSImage に 1 タイルを描画
        let tileSize = NSSize(width: tileW, height: tileH)
        let tileImage = NSImage(size: tileSize)
        tileImage.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        // 中央に配置 + 回転 (-30°)
        ctx.translateBy(x: tileW / 2, y: tileH / 2)
        ctx.rotate(by: -.pi / 6)
        ctx.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        tileImage.unlockFocus()

        guard let tileData = tileImage.tiffRepresentation,
              let tileBitmap = NSBitmapImageRep(data: tileData),
              let tileCG = tileBitmap.cgImage else {
            return image
        }

        // CIImage のタイルパターンを作成
        let tileCIImage = CIImage(cgImage: tileCG)
        // タイルを画面全体に敷き詰め、出力サイズにクロップ
        let tiled = tileCIImage
            .tiled(outputSize: renderSize)
        let outputRect = CGRect(origin: .zero, size: renderSize)
        let croppedTile = tiled.cropped(to: outputRect)
        return croppedTile.composited(over: image)
    }

    func cancelAllPendingVideoCompositionRequests() {
        // フレーム合成を中止する要求が来たら保留中の全リクエストを finishCancelledRequest() で終了する
        renderQueue.sync {
            for req in pendingRequests {
                req.finishCancelledRequest()
            }
            pendingRequests.removeAll()
        }
    }

    // MARK: - HDR -> SDR helpers

    private func detectTransferType(from pixelBuffer: CVPixelBuffer) -> Int {
        // 0 = unknown/SDR, 1 = PQ(ST2084), 2 = HLG
        if let rawAny = CVBufferGetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey as CFString, nil) {
            let rawStr = String(describing: rawAny)
            let lower = rawStr.lowercased()
            if lower.contains("pq") || lower.contains("2084") || lower.contains("st2084") { return 1 }
            if lower.contains("hlg") { return 2 }
        }

        // Fallback: sometimes transfer info is embedded in color space/profile fields
        if let cpAny = CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey as CFString, nil) {
            let s = String(describing: cpAny).lowercased()
            if s.contains("bt2020") || s.contains("p3") { /* could be HDR-ish but unknown transfer */ }
        }

        return 0
    }
    private func detectColorPrimaries(from pixelBuffer: CVPixelBuffer) -> Int {
        // 0 = unknown, 1 = BT.2020, 2 = DisplayP3, 3 = Rec.709/sRGB
        if let any = CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey as CFString, nil) {
            let s = String(describing: any).lowercased()
            if s.contains("bt2020") || s.contains("2020") { return 1 }
            if s.contains("p3") || s.contains("displayp3") { return 2 }
            if s.contains("bt709") || s.contains("rec709") || s.contains("srgb") { return 3 }
        }
        return 0
    }

}

// MARK: - CIImage tiling helper

private extension CIImage {
    /// タイルパターンとして画面全体に敷き詰める
    func tiled(outputSize: CGSize) -> CIImage {
        let tileW = extent.width
        let tileH = extent.height
        guard tileW > 0, tileH > 0 else { return self }
        var composite = CIImage.empty()
        var y: CGFloat = 0
        while y < outputSize.height {
            var x: CGFloat = 0
            while x < outputSize.width {
                let shifted = self.transformed(by: CGAffineTransform(translationX: x, y: y))
                composite = shifted.composited(over: composite)
                x += tileW
            }
            y += tileH
        }
        return composite
    }
}
