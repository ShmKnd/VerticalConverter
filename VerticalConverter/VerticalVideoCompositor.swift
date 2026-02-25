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

class VerticalVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.verticalconverter.renderqueue")
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext
    
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
            
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? AVVideoCompositionInstruction,
                  let layerInstruction = instruction.layerInstructions.first as? AVVideoCompositionLayerInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "VerticalVideoCompositor",
                    code: -1,
                    userInfo: nil
                ))
                return
            }
            
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
                renderSize: renderContext.size,
                time: asyncVideoCompositionRequest.compositionTime
            )
            
            asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputPixelBuffer)
        }
    }
    
    private func composeFrame(
        sourcePixelBuffer: CVPixelBuffer,
        outputPixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
        time: CMTime
    ) {
        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        
        // 出力サイズ
        let outputRect = CGRect(origin: .zero, size: renderSize)
        
        // ソース動画のサイズ
        let sourceSize = sourceImage.extent.size
        
        // 16:9を9:16に配置する際のスケール
        let scaleX = renderSize.width / sourceSize.width
        let scaleY = renderSize.height / sourceSize.height
        let scale = min(scaleX, scaleY)
        
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        
        // 中央配置のための位置
        let mainVideoRect = CGRect(
            x: (renderSize.width - scaledWidth) / 2,
            y: (renderSize.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        
        // 背景用：ブラーをかけて拡大した動画
        let backgroundScale = renderSize.height / sourceSize.height
        let backgroundWidth = sourceSize.width * backgroundScale
        let backgroundHeight = sourceSize.height * backgroundScale
        
        let backgroundRect = CGRect(
            x: (renderSize.width - backgroundWidth) / 2,
            y: 0,
            width: backgroundWidth,
            height: backgroundHeight
        )
        
        // 背景画像を作成（ブラー適用）
        let blurredBackground = sourceImage
            .transformed(by: CGAffineTransform(scaleX: backgroundScale, y: backgroundScale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .cropped(to: outputRect)
        
        // メイン動画を配置
        let mainVideo = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: mainVideoRect.origin.x,
                y: mainVideoRect.origin.y
            ))
        
        // 合成
        let composedImage = blurredBackground.composited(over: CIImage(color: .black).cropped(to: outputRect))
        let finalImage = mainVideo.composited(over: composedImage)
        
        // レンダリング
        ciContext.render(finalImage, to: outputPixelBuffer)
    }
    
    func cancelAllPendingVideoCompositionRequests() {
        // 必要に応じてキャンセル処理を実装
    }
}
