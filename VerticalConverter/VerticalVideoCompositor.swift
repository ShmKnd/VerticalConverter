//
//  VerticalVideoCompositor.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox
import Vision

class VerticalVideoCompositor: NSObject, AVVideoCompositing {
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
    // HDR -> SDR
    private var hdrConversionEnabled: Bool = false
    private var hdrTarget: CustomVideoCompositionInstruction.HDRTarget = .sRGB
    override init() {
        // Use extended linear sRGB as working color space so CoreImage can
        // represent HDR values (> 1.0) without clipping during compositing.
        let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext = CIContext(options: [.workingColorSpace: workingCS])
        super.init()
    }
    
    var sourcePixelBufferAttributes: [String : Any]? {
        // Accept both 64RGBAHalf (for HDR passthrough) and 32BGRA (SDR fallback).
        // AVFoundation will prefer the first matching format it can provide.
        return [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_64RGBAHalf,
                kCVPixelFormatType_32BGRA
            ] as [OSType],
            kCVPixelBufferOpenGLCompatibilityKey as String: true
        ]
    }
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] {
        // Use 64RGBAHalf so the render output buffer can hold HDR values (>1.0)
        // without clipping. CIContext renders to this format correctly.
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferOpenGLCompatibilityKey as String: true
        ]
    }
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            renderContext = newRenderContext
        }
    }
    
    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self = self else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
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
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                removePending()
                return
            }
            
            guard let layerInstruction = instruction.layerInstructions.first as? AVVideoCompositionLayerInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                removePending()
                return
            }
            
            // スマートフレーミング設定を取得
            self.smartFramingEnabled = instruction.smartFramingEnabled
            self.dampingFactor = instruction.dampingFactor
            self.currentPrecomputedOffsets = instruction.precomputedOffsets
            self.letterboxMode = instruction.letterboxMode
            // HDR settings
            let hdrEnabled = instruction.hdrConversionEnabled
            let hdrTarget = instruction.hdrTarget
            // store in local vars for composeFrame
            self.hdrConversionEnabled = hdrEnabled
            self.hdrTarget = hdrTarget

            guard let sourcePixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: layerInstruction.trackID) else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                removePending()
                return
            }
            
            // 出力バッファを作成
            guard let renderContext = self.renderContext,
                  let outputPixelBuffer = renderContext.newPixelBuffer() else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
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
        }
    }
    
    private func composeFrame(
        sourcePixelBuffer: CVPixelBuffer,
        outputPixelBuffer: CVPixelBuffer,
        renderSize: CGSize
    ) {
        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
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

        let imageToRender = finalImage

        if hdrConversionEnabled {
            // HDR->SDR: CoreImage color space conversion handles the EOTF mapping
            // during the render call below. Mark output buffer as Rec.709 / sRGB.
            let primariesStr = NSString(string: "ITU_R_709_2")
            let transferStr = NSString(string: "ITU_R_709_2")
            let matrixStr = NSString(string: "ITU_R_709_2")
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferColorPrimariesKey as CFString, primariesStr, .shouldPropagate)
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferTransferFunctionKey as CFString, transferStr, .shouldPropagate)
            CVBufferSetAttachment(outputPixelBuffer, kCVImageBufferYCbCrMatrixKey as CFString, matrixStr, .shouldPropagate)
        } else {
            // Preserve HDR metadata: copy color attachments from source to output when present
            let attachKeys: [CFString] = [
                kCVImageBufferColorPrimariesKey as CFString,
                kCVImageBufferTransferFunctionKey as CFString,
                kCVImageBufferYCbCrMatrixKey as CFString,
                kCVImageBufferMasteringDisplayColorVolumeKey as CFString,
                kCVImageBufferContentLightLevelInfoKey as CFString
            ]
            func makeCFCompatible(_ any: Any) -> CFTypeRef? {
                if let ns = any as? NSString { return ns }
                if let s = any as? String { return NSString(string: s) }
                if let num = any as? NSNumber { return num }
                if let dict = any as? NSDictionary { return dict }
                if let dict = any as? [AnyHashable: Any] { return dict as NSDictionary }
                if let arr = any as? NSArray { return arr }
                if let arr = any as? [Any] { return arr as NSArray }
                // As a last resort, attach a string description to avoid passing
                // Swift-only boxed values into CoreVideo/IOSurface.
                return NSString(string: String(describing: any))
            }

            for key in attachKeys {
                if let val = CVBufferGetAttachment(sourcePixelBuffer, key, nil) {
                    if let cf = makeCFCompatible(val) {
                        CVBufferSetAttachment(outputPixelBuffer, key, cf, .shouldPropagate)
                    }
                }
            }
        }

        // Render: when HDR->SDR is enabled we render into the SDR color space
        // (Rec.709 or sRGB). When preserving HDR, render without a target
        // colorSpace so original color values are preserved and metadata
        // describes the colorimetry.
        if hdrConversionEnabled {
            // Render to the SDR target color space. CoreImage performs the color
            // space conversion (including EOTF linearization) from the source
            // color space that CIImage auto-detects from the pixel buffer.
            let targetCS: CGColorSpace
            switch hdrTarget {
            case .sRGB:
                targetCS = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            case .rec709:
                targetCS = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
            }
            ciContext.render(imageToRender, to: outputPixelBuffer, bounds: imageToRender.extent, colorSpace: targetCS)
        } else {
            // Passthrough: render to the source buffer's own color space so no
            // accidental conversion takes place. Falls back to Rec.709 for
            // untagged SDR buffers.
            let sourceCS: CGColorSpace = CVImageBufferGetColorSpace(sourcePixelBuffer)?.takeUnretainedValue()
                ?? CGColorSpace(name: CGColorSpace.itur_709)
                ?? CGColorSpaceCreateDeviceRGB()
            ciContext.render(imageToRender, to: outputPixelBuffer, bounds: imageToRender.extent, colorSpace: sourceCS)
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
            let mainY = (renderSize.height - scaledHeight) / 2

            let mainVideo = sourceImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: mainX, y: mainY))

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
            let cropX = (sourceSize.width - cropW) / 2
            cropRect = CGRect(x: cropX, y: 0, width: cropW, height: sourceSize.height)
        } else {
            // 元が縦長または同等 -> 縦をトリミング
            let cropH = sourceSize.width / targetAspect
            let cropY = (sourceSize.height - cropH) / 2
            cropRect = CGRect(x: 0, y: cropY, width: sourceSize.width, height: cropH)
        }

        let cropped = sourceImage.cropped(to: cropRect)

        // メイン映像は幅に合わせてスケール（左右を若干トリミングして中央を強調）
        let scale = renderSize.width / cropRect.width
        let scaledHeight = cropRect.height * scale
        let mainY = (renderSize.height - scaledHeight) / 2

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

        // 初回フレーム: 中央に初期化
        if isFirstSmartFrame {
            isFirstSmartFrame = false
            currentOffsetX = minOffsetX / 2
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
    // Previously a custom CIColorKernel handled inverse-EOTF, IDT and RRT.
    // For now, remove the custom tonemapper and use a simpler CI-based
    // path (linearization/exposure + gamma) to validate pipeline behavior.

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

    // applyHDRToSDR removed: HDR->SDR conversion is now handled entirely by
    // CoreImage's color space management at render time. The CIImage retains
    // the source color space (auto-detected from the CVPixelBuffer), and
    // rendering to a Rec.709/sRGB CGColorSpace performs the correct EOTF
    // mapping without the double-processing that broke SDR passthrough.
}
