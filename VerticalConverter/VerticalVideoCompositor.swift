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
    private var smoothedTargetOffsetX: CGFloat = 0  // ターゲット自体もスムージング
    private var rawTargetOffsetX: CGFloat = 0       // Vision検出生値
    private var frameCount: Int = 0
    private let detectionInterval: Int = 8          // 何フレームごとに検出するか
    private var lastDetectedNormalizedX: CGFloat? = nil
    
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

        // 一定フレーム間隔でのみVision検出を実行（重い処理を間引く）
        frameCount += 1
        if frameCount % detectionInterval == 0 {
            detectPersonNormalizedX(in: sourcePixelBuffer)
        }

        // 検出値からrawTargetを計算
        let minOffsetX = -(scaledWidth - renderSize.width)
        if let normalizedX = lastDetectedNormalizedX {
            let personX = normalizedX * scaledWidth
            let desired = renderSize.width / 2 - personX
            rawTargetOffsetX = max(minOffsetX, min(0, desired))
        } else {
            rawTargetOffsetX = minOffsetX / 2
        }

        // ターゲット自体をゆっくり動かす（検出間隔のジャンプを滑らかに）
        smoothedTargetOffsetX += (rawTargetOffsetX - smoothedTargetOffsetX) * 0.04

        // currentをsmoothTargetに追従（ダンピング適用）
        currentOffsetX += (smoothedTargetOffsetX - currentOffsetX) * dampingFactor

        // 動画をズームして左右クロップ
        return sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: currentOffsetX, y: 0))
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

        guard !allPersonsX.isEmpty else { return }

        if allPersonsX.count == 1 {
            // 1人: そのままの位置
            lastDetectedNormalizedX = allPersonsX[0]
        } else {
            // 複数人: 全員を包むバウンディングボックスの中心を使用
            let minX = allPersonsX.min()!
            let maxX = allPersonsX.max()!
            lastDetectedNormalizedX = (minX + maxX) / 2
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
