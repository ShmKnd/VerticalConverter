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
    private var targetOffsetX: CGFloat = 0
    
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
        // 縦いっぱいにズームするスケール
        let scale = renderSize.height / sourceSize.height
        let scaledWidth = sourceSize.width * scale

        // 人物検出でX方向ターゲットオフセットを更新
        detectPersonAndUpdateTargetOffsetX(
            in: sourcePixelBuffer,
            sourceSize: sourceSize,
            scaledWidth: scaledWidth,
            renderWidth: renderSize.width
        )

        // ダンピングでスムーズに追従
        currentOffsetX += (targetOffsetX - currentOffsetX) * dampingFactor

        // 動画をズームして左右クロップ
        return sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: currentOffsetX, y: 0))
            .cropped(to: outputRect)
    }
    
    // MARK: - 人物検出（X位置追跡）

    private func detectPersonAndUpdateTargetOffsetX(
        in pixelBuffer: CVPixelBuffer,
        sourceSize: CGSize,
        scaledWidth: CGFloat,
        renderWidth: CGFloat
    ) {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest]) } catch { return }

        var detectedNormalizedX: CGFloat? = nil

        // 人体ポーズ検出（優先）
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            var totalX: CGFloat = 0
            var count: CGFloat = 0
            for observation in bodyResults {
                if let points = try? observation.recognizedPoints(.all) {
                    let upperPoints = [
                        points[.neck], points[.leftShoulder],
                        points[.rightShoulder], points[.nose]
                    ].compactMap { $0 }.filter { $0.confidence > 0.3 }
                    if !upperPoints.isEmpty {
                        // Vision X座標: 左=0、右=1
                        let avgX = upperPoints.reduce(0.0) { $0 + $1.location.x } / CGFloat(upperPoints.count)
                        totalX += avgX
                        count += 1
                    }
                }
            }
            if count > 0 { detectedNormalizedX = totalX / count }
        }

        // 顔検出（フォールバック）
        if detectedNormalizedX == nil, let faceResults = faceRequest.results, !faceResults.isEmpty {
            var totalX: CGFloat = 0
            for face in faceResults { totalX += face.boundingBox.midX }
            detectedNormalizedX = totalX / CGFloat(faceResults.count)
        }

        // offsetX の範囲: 動画が左右にはみ出さないように制限
        let minOffsetX = -(scaledWidth - renderWidth)  // 右端を画面右端に合わせた場合
        let maxOffsetX: CGFloat = 0                    // 左端を画面左端に合わせた場合

        if let normalizedX = detectedNormalizedX {
            let personXInScaledVideo = normalizedX * scaledWidth
            let desiredOffsetX = renderWidth / 2 - personXInScaledVideo
            targetOffsetX = max(minOffsetX, min(maxOffsetX, desiredOffsetX))
        } else {
            // 未検出時は中央
            targetOffsetX = minOffsetX / 2
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
