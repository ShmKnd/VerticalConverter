//
//  VerticalVideoCompositor.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox
import Vision

class VerticalVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.verticalconverter.renderqueue")
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext
    
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
    override init() {
        ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
        super.init()
    }
    
    var sourcePixelBufferAttributes: [String : Any]? {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLCompatibilityKey as String: true
        ]
    }
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
            
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? CustomVideoCompositionInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                return
            }
            
            guard let layerInstruction = instruction.layerInstructions.first as? AVVideoCompositionLayerInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                return
            }
            
            // スマートフレーミング設定を取得
            self.smartFramingEnabled = instruction.smartFramingEnabled
            self.dampingFactor = instruction.dampingFactor
            self.currentPrecomputedOffsets = instruction.precomputedOffsets

            guard let sourcePixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: layerInstruction.trackID) else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
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
                return
            }
            
            // フレームを合成
            self.composeFrame(
                sourcePixelBuffer: sourcePixelBuffer,
                outputPixelBuffer: outputPixelBuffer,
                renderSize: renderContext.size
            )
            
            asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputPixelBuffer)
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
                renderSize: renderSize, outputRect: outputRect
            )
        }

        ciContext.render(finalImage, to: outputPixelBuffer)
    }

    // MARK: - レターボックス

    private func makeLetterboxImage(
        sourceImage: CIImage,
        sourceSize: CGSize,
        renderSize: CGSize,
        outputRect: CGRect
    ) -> CIImage {
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

    func cancelAllPendingVideoCompositionRequests() {}
}
