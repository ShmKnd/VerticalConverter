//
//  SmartFramingAnalyzer.swift
//  VerticalConverter
//
//  動画全体を事前解析してフレームごとのカメラオフセットを計算する（2パス処理）
//

import AVFoundation
import Vision

struct SmartFramingAnalyzer {

    private let detectionInterval: Int = 8  // 何フレームごとに Vision を実行するか

    // MARK: - Public

    /// 動画全体を解析し、フレームごとの offsetX（スケール済みピクセル）を配列で返す。
    /// - precomputedOffsets[i] = フレームiでのカメラ左端オフセット（負値または0）
    func analyze(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        inputSize: CGSize,
        outputSize: CGSize,
        followFactor: CGFloat = 0.06,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> [CGFloat] {
        let duration    = try await asset.load(.duration)
        let fps         = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = max(1, Int(ceil(duration.seconds * Double(fps))))

        // 出力座標系でのスケール
        let scale        = outputSize.height / inputSize.height
        let scaledWidth  = inputSize.width  * scale
        let minOffsetX   = -(scaledWidth - outputSize.width)
        let centerOffset = minOffsetX / 2

        // Step 1: 全フレームをスキャンして人物 X 座標を取得（N フレームごと）
        let rawPositions = try await detectAllPositions(
            asset: asset,
            videoTrack: videoTrack,
            totalFrames: totalFrames,
            progressHandler: { progressHandler($0 * 0.85) }
        )

        // Step 2: nil を線形補間で埋める
        let interpolated = interpolate(rawPositions, fallback: 0.5)

        // Step 3: 双方向ガウシアンスムージング
        //   未来フレームも含めて平滑化できるのが2パスの利点
        //   sigma=20 フレーム ≈ 30fps で約 0.7 秒の平滑化半径
        let smoothed = gaussianSmooth(interpolated, sigma: 20.0)

        // Step 4: ホールド＆フォロー（デッドゾーン）
        //   3秒ホールド後、人物がデッドゾーン外にずれていたらスムーズパンで追従
        //   2パス処理のため未来フレームのガウシアン平滑化済み座標を使用しジャンプなし
        let minHoldFrames = Int(3.0 * Double(fps))
        let offsets = holdAndFollow(
            smoothed,
            scaledWidth: scaledWidth,
            renderWidth: outputSize.width,
            minOffsetX: minOffsetX,
            centerOffsetX: centerOffset,
            deadZoneRatio: 0.25,
            minHoldFrames: minHoldFrames,
            followFactor: followFactor
        )

        progressHandler(1.0)
        return offsets
    }

    // MARK: - Step 1: Vision 検出

    private func detectAllPositions(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        totalFrames: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> [CGFloat?] {
        var result = [CGFloat?](repeating: nil, count: totalFrames)

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
                result[frameIndex] = detectPersonX(in: pixelBuffer)
            }

            frameIndex += 1
            if frameIndex % 30 == 0 {
                progressHandler(min(Double(frameIndex) / Double(totalFrames), 1.0))
            }
        }

        return result
    }

    private func detectPersonX(in pixelBuffer: CVPixelBuffer) -> CGFloat? {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest]) } catch { return nil }

        var allX: [CGFloat] = []

        // 人体ポーズ優先
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            for obs in bodyResults {
                if let points = try? obs.recognizedPoints(.all) {
                    let upper = [points[.neck], points[.leftShoulder],
                                 points[.rightShoulder], points[.nose]]
                        .compactMap { $0 }.filter { $0.confidence > 0.3 }
                    if !upper.isEmpty {
                        let avgX = upper.map { $0.location.x }.reduce(0, +) / CGFloat(upper.count)
                        allX.append(avgX)
                    }
                }
            }
        }

        // 顔検出フォールバック
        if allX.isEmpty, let faces = faceRequest.results, !faces.isEmpty {
            allX = faces.map { $0.boundingBox.midX }
        }

        guard !allX.isEmpty else { return nil }
        // 複数人: バウンディングボックス中心
        return (allX.min()! + allX.max()!) / 2
    }

    // MARK: - Step 2: 線形補間

    private func interpolate(_ positions: [CGFloat?], fallback: CGFloat) -> [CGFloat] {
        let n = positions.count
        var result = [CGFloat](repeating: fallback, count: n)

        guard let firstKnown = positions.firstIndex(where: { $0 != nil }),
              let lastKnown  = positions.lastIndex(where:  { $0 != nil }) else {
            return result  // 全フレーム未検出 → 中央 (fallback=0.5)
        }

        // 先頭部分を最初の既知値で埋める
        for i in 0..<firstKnown { result[i] = positions[firstKnown]! }

        // 既知値間を線形補間
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

        // 末尾部分を最後の既知値で埋める
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

    // MARK: - Step 4: ホールド＆フォロー

    /// 3秒ホールド後、人物がデッドゾーン外にいれば lerp でスムーズパン追従する。
    /// followFactor: 1フレームあたりの追従割合（0.06 ≈ 30fpsで約1秒でほぼ到達）
    private func holdAndFollow(
        _ positions: [CGFloat],
        scaledWidth: CGFloat,
        renderWidth: CGFloat,
        minOffsetX: CGFloat,
        centerOffsetX: CGFloat,
        deadZoneRatio: CGFloat,
        minHoldFrames: Int,
        followFactor: CGFloat = 0.06
    ) -> [CGFloat] {
        var offsets      = [CGFloat](repeating: centerOffsetX, count: positions.count)
        var cameraOffset = centerOffsetX
        let deadZone     = renderWidth * deadZoneRatio
        var settledFrame = -minHoldFrames   // 最初のフレームは即フォロー可能
        var isFollowing  = false

        for i in 0..<positions.count {
            let personX      = positions[i] * scaledWidth
            let targetOffset = max(minOffsetX, min(0, renderWidth / 2 - personX))
            let deviation    = abs(targetOffset - cameraOffset)
            let holdElapsed  = i - settledFrame

            if isFollowing {
                // パン中: ターゲットへ向けて lerp
                cameraOffset += (targetOffset - cameraOffset) * followFactor
                // 2px 以内に収まったら完了 → ホールド開始
                if abs(targetOffset - cameraOffset) < 2.0 {
                    cameraOffset = targetOffset
                    isFollowing  = false
                    settledFrame = i
                }
            } else {
                // ホールド中: デッドゾーン外かつホールド期間を過ぎたらフォロー開始
                if deviation > deadZone && holdElapsed >= minHoldFrames {
                    isFollowing  = true
                    cameraOffset += (targetOffset - cameraOffset) * followFactor
                }
                // デッドゾーン内 or ホールド中は静止
            }

            offsets[i] = cameraOffset
        }
        return offsets
    }
}
