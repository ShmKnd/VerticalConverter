//
//  SmartFramingAnalyzer.swift
//  VerticalConverter
//
//  動画全体を事前解析してフレームごとのカメラオフセットを計算する（2パス処理）
//

import AVFoundation
import Vision

struct SmartFramingAnalyzer {

    /// Y方向パン余白確保のための均一ズーム倍率（10%ズームイン）
    static let yZoomFactor: CGFloat = 1.1

    // MARK: - Public

    /// 動画全体を解析し、フレームごとの (offsetX, offsetY) を CGPoint 配列で返す。
    /// - .x = カメラ左端オフセット（ピクセル、負値または0）
    /// - .y = カメラ下端オフセット（ピクセル、負値または0）
    func analyze(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        inputSize: CGSize,
        outputSize: CGSize,
        followFactor: CGFloat = 0.06,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> [CGPoint] {
        let duration    = try await asset.load(.duration)
        let fps         = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = max(1, Int(ceil(duration.seconds * Double(fps))))

        // ① fps依存のガウシアン sigma（≈ 0.4秒分の平滑化半径）
        //   30fps → sigma=12, 60fps → sigma=24, 24fps → sigma=9.6
        let sigma = Double(fps) * 0.4

        // スケール（Y方向ズーム込み）
        let zoomFactor   = SmartFramingAnalyzer.yZoomFactor
        let scale        = outputSize.height / inputSize.height * zoomFactor
        let scaledWidth  = inputSize.width  * scale
        let scaledHeight = inputSize.height * scale

        let minOffsetX    = -(scaledWidth  - outputSize.width)
        let minOffsetY    = -(scaledHeight - outputSize.height)   // 負値（上シフト上限）
        let centerOffsetX = minOffsetX / 2
        let centerOffsetY = minOffsetY / 2                         // 上下中央を初期位置

        // Step 1: 全フレームをスキャンして人物 XY 座標を取得（③ 適応的間隔）
        let rawPositions = try await detectAllPositions(
            asset: asset,
            videoTrack: videoTrack,
            totalFrames: totalFrames,
            progressHandler: { progressHandler($0 * 0.85) }
        )

        // Step 2: X・Y を別々に補間
        let rawX = rawPositions.map { $0.map { $0.x } }
        let rawY = rawPositions.map { $0.map { $0.y } }
        let interpX = interpolate(rawX, fallback: 0.5)
        let interpY = interpolate(rawY, fallback: 0.72)   // 未検出時は上から28%付近

        // Step 3: 双方向ガウシアンスムージング（fps依存 sigma）
        let smoothedX = gaussianSmooth(interpX, sigma: sigma)
        let smoothedY = gaussianSmooth(interpY, sigma: sigma)

        // Step 4X: X方向 ホールド＆フォロー（3秒ホールド、25%デッドゾーン）
        let minHoldFrames = Int(3.0 * Double(fps))
        let offsetsX = holdAndFollow(
            smoothedX,
            scaledDimension: scaledWidth,
            renderDimension: outputSize.width,
            minOffset: minOffsetX,
            centerOffset: centerOffsetX,
            targetRatio: 0.5,          // X: 画面中央に被写体
            deadZoneRatio: 0.25,
            minHoldFrames: minHoldFrames,
            followFactor: followFactor
        )

        // Step 4Y: Y方向 ホールド＆フォロー（0.5秒ホールド、ヘッドルーム優先）
        //   headroomTarget=0.80 → 上から20%のヘッドルームを確保して上半身を配置
        let offsetsY = holdAndFollow(
            smoothedY,
            scaledDimension: scaledHeight,
            renderDimension: outputSize.height,
            minOffset: minOffsetY,
            centerOffset: centerOffsetY,
            targetRatio: 0.80,         // Y: 上から20%ヘッドルーム
            deadZoneRatio: 0.08,       // 狭いデッドゾーン（Yは細かく追従）
            minHoldFrames: max(1, Int(0.5 * Double(fps))),
            followFactor: followFactor * 1.5
        )

        progressHandler(1.0)
        return zip(offsetsX, offsetsY).map { CGPoint(x: $0, y: $1) }
    }

    // MARK: - Step 1: Vision 検出（③ 適応的間隔）

    private func detectAllPositions(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        totalFrames: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> [CGPoint?] {
        var result = [CGPoint?](repeating: nil, count: totalFrames)
        var detectionInterval = 8      // ③ 適応的間隔: 初期8、激しい動きで4に短縮
        var lastDetectedPos: CGPoint? = nil

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return result }
        reader.add(output)
        reader.startReading()

        var frameIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }

            if frameIndex % detectionInterval == 0,
               frameIndex < totalFrames,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                if let detected = detectPersonXY(in: pixelBuffer) {
                    // ③ 動き量が大きい場合は間隔を短縮（0.12以上の偏差で激しい動きと判定）
                    if let last = lastDetectedPos {
                        let deviation = hypot(detected.x - last.x, detected.y - last.y)
                        detectionInterval = deviation > 0.12 ? 4 : 8
                    }
                    result[frameIndex] = detected
                    lastDetectedPos = detected
                }
            }

            frameIndex += 1
            if frameIndex % 30 == 0 {
                progressHandler(min(Double(frameIndex) / Double(totalFrames), 1.0))
            }
        }

        return result
    }

    /// ② 複数人物を信頼度・画面中央近傍・面積で重み付き平均して代表 XY を返す。
    /// Vision 座標系: x=0左/1右, y=0下/1上
    private func detectPersonXY(in pixelBuffer: CVPixelBuffer) -> CGPoint? {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest]) } catch { return nil }

        struct Candidate { var x, y, weight: CGFloat }
        var candidates: [Candidate] = []

        // ① 人体ポーズ優先: 上半身キーポイントの加重平均 ×（信頼度 × 中央近傍度）
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            for obs in bodyResults {
                guard let points = try? obs.recognizedPoints(.all) else { continue }
                let upper = [points[.neck], points[.leftShoulder],
                             points[.rightShoulder], points[.nose],
                             points[.leftEar], points[.rightEar]]
                    .compactMap { $0 }.filter { $0.confidence > 0.3 }
                guard !upper.isEmpty else { continue }
                let avgConf = upper.map { CGFloat($0.confidence) }.reduce(0, +) / CGFloat(upper.count)
                let avgX = upper.map { $0.location.x }.reduce(0, +) / CGFloat(upper.count)
                let avgY = upper.map { $0.location.y }.reduce(0, +) / CGFloat(upper.count)
                // 中央近傍ほど高重み（中央から遠いほど減衰）
                let centerWeight = max(0.2, 1.0 - abs(avgX - 0.5) * 1.6)
                candidates.append(Candidate(x: avgX, y: avgY, weight: avgConf * centerWeight))
            }
        }

        // ② 顔検出フォールバック: 面積 × 中央近傍度で重み付け
        if candidates.isEmpty, let faces = faceRequest.results, !faces.isEmpty {
            for face in faces {
                let bb = face.boundingBox
                let area = bb.width * bb.height
                let centerWeight = max(0.2, 1.0 - abs(bb.midX - 0.5) * 1.6)
                candidates.append(Candidate(x: bb.midX, y: bb.midY, weight: area * centerWeight))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // 重み付き平均
        let totalW = candidates.map(\.weight).reduce(0, +)
        guard totalW > 0 else { return nil }
        let wx = candidates.map { $0.x * $0.weight }.reduce(0, +) / totalW
        let wy = candidates.map { $0.y * $0.weight }.reduce(0, +) / totalW
        return CGPoint(x: wx, y: wy)
    }

    // MARK: - Step 2: 線形補間

    private func interpolate(_ positions: [CGFloat?], fallback: CGFloat) -> [CGFloat] {
        let n = positions.count
        var result = [CGFloat](repeating: fallback, count: n)

        guard let firstKnown = positions.firstIndex(where: { $0 != nil }),
              let lastKnown  = positions.lastIndex(where:  { $0 != nil }) else {
            return result
        }

        for i in 0..<firstKnown { result[i] = positions[firstKnown]! }

        var prevIdx = firstKnown
        var prevVal = positions[firstKnown]!
        result[firstKnown] = prevVal

        for i in (firstKnown + 1)...lastKnown {
            if let val = positions[i] {
                let span = i - prevIdx
                for j in prevIdx..<i {
                    let t = CGFloat(j - prevIdx) / CGFloat(span)
                    result[j] = prevVal + (val - prevVal) * t
                }
                result[i] = val
                prevIdx = i
                prevVal = val
            }
        }

        for i in (lastKnown + 1)..<n { result[i] = positions[lastKnown]! }
        return result
    }

    // MARK: - Step 3: 双方向ガウシアンスムージング

    private func gaussianSmooth(_ values: [CGFloat], sigma: Double) -> [CGFloat] {
        let n = values.count
        guard n > 1 else { return values }

        let radius = Int(ceil(sigma * 3))
        var kernel = [Double]()
        for i in -radius...radius {
            kernel.append(exp(-Double(i * i) / (2 * sigma * sigma)))
        }
        let kernelSum = kernel.reduce(0, +)
        let normKernel = kernel.map { $0 / kernelSum }

        var result = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            var weighted = 0.0
            var wSum     = 0.0
            for (j, w) in normKernel.enumerated() {
                let idx = i + j - radius
                if idx >= 0 && idx < n {
                    weighted += Double(values[idx]) * w
                    wSum     += w
                }
            }
            result[i] = CGFloat(weighted / wSum)
        }
        return result
    }

    // MARK: - Step 4: 汎用 ホールド＆フォロー

    /// - targetRatio: 被写体をレンダーフレーム内のどの位置（下から何割）に置くか
    ///   X軸 = 0.5（中央）, Y軸 = 0.80（上から20%のヘッドルーム）
    private func holdAndFollow(
        _ positions: [CGFloat],
        scaledDimension: CGFloat,
        renderDimension: CGFloat,
        minOffset: CGFloat,
        centerOffset: CGFloat,
        targetRatio: CGFloat,
        deadZoneRatio: CGFloat,
        minHoldFrames: Int,
        followFactor: CGFloat
    ) -> [CGFloat] {
        var offsets      = [CGFloat](repeating: centerOffset, count: positions.count)
        var cameraOffset = centerOffset
        let deadZone     = renderDimension * deadZoneRatio
        var settledFrame = -minHoldFrames
        var isFollowing  = false

        for i in 0..<positions.count {
            // Vision 正規化座標 → スケール済みピクセル座標（CIImage: 0=下）
            let personPos    = positions[i] * scaledDimension
            // 被写体を targetRatio の位置に置くオフセット
            let targetOffset = max(minOffset, min(0, renderDimension * targetRatio - personPos))
            let deviation    = abs(targetOffset - cameraOffset)
            let holdElapsed  = i - settledFrame

            if isFollowing {
                cameraOffset += (targetOffset - cameraOffset) * followFactor
                if abs(targetOffset - cameraOffset) < 2.0 {
                    cameraOffset = targetOffset
                    isFollowing  = false
                    settledFrame = i
                }
            } else {
                if deviation > deadZone && holdElapsed >= minHoldFrames {
                    isFollowing  = true
                    cameraOffset += (targetOffset - cameraOffset) * followFactor
                }
            }

            offsets[i] = cameraOffset
        }
        return offsets
    }
}
