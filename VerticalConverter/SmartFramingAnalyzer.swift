//
//  SmartFramingAnalyzer.swift
//  VerticalConverter
//
//  動画全体を事前解析してフレームごとのカメラオフセットを計算する（2パス処理）
//  人物追跡: IOUベーストラッキング → 寿命・速度による主役推定
//

@preconcurrency import AVFoundation
import Vision

// MARK: - Data Types

/// 1フレームにおける1人分の生検出結果（Vision正規化座標）
private struct RawPerson {
    var x: CGFloat          // 上半身中心 X（0=左, 1=右）
    var y: CGFloat          // 上半身中心 Y（0=下, 1=上）
    var w: CGFloat          // バウンディング幅（IOUマッチング用）
    var h: CGFloat          // バウンディング高さ
    var confidence: CGFloat
}

/// IOUトラッカーが管理する個人の追跡状態
private struct TrackedPerson {
    let id: Int
    var x, y, w, h: CGFloat
    var confidence: CGFloat
    var lifespan: Int           // 検出成功フレーム数の累計
    var missedFrames: Int       // 連続未検出フレーム数
    var velocities: [CGFloat]   // 直近の移動量（正規化座標/検出間隔）
    var lastX: CGFloat?         // 前フレームの中心X（速度計算用）

    var avgVelocity: CGFloat {
        guard !velocities.isEmpty else { return 0 }
        return velocities.reduce(0, +) / CGFloat(velocities.count)
    }
}

// MARK: - Person Tracker

/// IOUベースのシンプルなパーソントラッカー
/// 各人物に寿命・速度を蓄積し「主役らしさ」スコアを提供する
private final class PersonTracker {
    private var tracked: [TrackedPerson] = []
    private var nextID: Int = 0
    private let iouThreshold: CGFloat = 0.20
    private let maxMissed: Int = 5          // 連続5検出間隔（≈40フレーム）で削除
    private let maxVelocityHistory: Int = 6

    /// fps × 1.5秒 = 主役と判定するのに必要な最低寿命フレーム数
    var lifespanTarget: CGFloat = 45

    /// 検出フレームごとに呼び出す。追跡状態を更新し、加重中心点を返す。
    /// - Returns: 主役推定済みの加重 (x, y)、全員消えた場合は nil
    func update(with rawPersons: [RawPerson]) -> CGPoint? {
        if rawPersons.isEmpty {
            // 全員未検出: missedFrames を増加させてタイムアウト削除
            for i in tracked.indices { tracked[i].missedFrames += 1 }
            tracked.removeAll { $0.missedFrames > maxMissed }
            // ただし maxMissed 以内のトラックが残っている間は
            // 最後に既知だった加重中心を返してホールド挙動にする
            if !tracked.isEmpty {
                return weightedCenterAllowingMissed()
            }
            return nil
        }

        // ── IOU グリーディマッチング ──
        var matched = Set<Int>()        // rawPersons のindex
        var updatedTracked: [TrackedPerson] = []

        for var tp in tracked {
            // このトラックに最もIOUが高い未マッチ検出を探す
            var bestIOU: CGFloat = iouThreshold
            var bestIdx: Int = -1
            for (ri, rp) in rawPersons.enumerated() where !matched.contains(ri) {
                let score = iou(tp, rp)
                if score > bestIOU { bestIOU = score; bestIdx = ri }
            }

            if bestIdx >= 0 {
                let rp = rawPersons[bestIdx]
                matched.insert(bestIdx)

                // 速度を記録（前フレームとのX距離）
                let vel: CGFloat
                if let lx = tp.lastX {
                    vel = abs(rp.x - lx)
                } else {
                    vel = 0
                }
                var newVels = tp.velocities + [vel]
                if newVels.count > maxVelocityHistory { newVels.removeFirst() }

                tp.x = rp.x; tp.y = rp.y; tp.w = rp.w; tp.h = rp.h
                tp.confidence = rp.confidence
                tp.lifespan += 1
                tp.missedFrames = 0
                tp.velocities = newVels
                tp.lastX = rp.x
                updatedTracked.append(tp)
            } else {
                tp.missedFrames += 1
                if tp.missedFrames <= maxMissed { updatedTracked.append(tp) }
            }
        }

        // 未マッチの検出 → 新規トラック
        for (ri, rp) in rawPersons.enumerated() where !matched.contains(ri) {
            updatedTracked.append(TrackedPerson(
                id: nextID, x: rp.x, y: rp.y, w: rp.w, h: rp.h,
                confidence: rp.confidence, lifespan: 1, missedFrames: 0,
                velocities: [], lastX: rp.x
            ))
            nextID += 1
        }

        tracked = updatedTracked

        // ── 主役スコアで加重平均 ──
        return weightedCenter()
    }

    // MARK: - Score & Center

    private func weightedCenter() -> CGPoint? {
        let active = tracked.filter { $0.missedFrames == 0 }
        guard !active.isEmpty else { return nil }

        var totalW: CGFloat = 0
        var wx: CGFloat = 0
        var wy: CGFloat = 0

        for tp in active {
            let w = subjectScore(tp)
            wx += tp.x * w
            wy += tp.y * w
            totalW += w
        }
        guard totalW > 0 else { return nil }
        return CGPoint(x: wx / totalW, y: wy / totalW)
    }

    /// missedFrames が 0 でないトラックも許容して加重中心を返す（ホールド用）
    private func weightedCenterAllowingMissed() -> CGPoint? {
        guard !tracked.isEmpty else { return nil }
        var totalW: CGFloat = 0
        var wx: CGFloat = 0
        var wy: CGFloat = 0
        for tp in tracked {
            let w = subjectScore(tp)
            wx += tp.x * w
            wy += tp.y * w
            totalW += w
        }
        guard totalW > 0 else { return nil }
        return CGPoint(x: wx / totalW, y: wy / totalW)
    }

    /// 人物ごとの「主役らしさ」スコア
    ///   = confidence × centrality × lifespanWeight × motionWeight
    private func subjectScore(_ tp: TrackedPerson) -> CGFloat {
        // 寿命重み: 1.5秒以上存在すれば 1.0
        let lifespanWeight = min(1.0, CGFloat(tp.lifespan) / lifespanTarget)
        // 速度重み: 速い人物（通過者）は減衰
        let motionWeight = 1.0 / (1.0 + tp.avgVelocity * 6.0)
        // 中央近傍: 画面端は減衰
        let centrality = max(0.2, 1.0 - abs(tp.x - 0.5) * 1.6)
        return tp.confidence * centrality * lifespanWeight * motionWeight
    }

    // MARK: - IOU Helper

    private func iou(_ a: TrackedPerson, _ b: RawPerson) -> CGFloat {
        let ax1 = a.x - a.w/2, ax2 = a.x + a.w/2
        let ay1 = a.y - a.h/2, ay2 = a.y + a.h/2
        let bx1 = b.x - b.w/2, bx2 = b.x + b.w/2
        let by1 = b.y - b.h/2, by2 = b.y + b.h/2
        let iw = max(0, min(ax2, bx2) - max(ax1, bx1))
        let ih = max(0, min(ay2, by2) - max(ay1, by1))
        let inter = iw * ih
        let union = a.w*a.h + b.w*b.h - inter
        return union > 0 ? inter / union : 0
    }
}

// MARK: - SmartFramingAnalyzer

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

        // ① fps依存の EMA α（指数移動平均）
        //   α = 1 / (1 + fps × 0.2)  → 直近フレームへの重み
        //   24fps → α≈0.17, 30fps → α≈0.14, 60fps → α≈0.08
        let emaAlpha = 1.0 / (1.0 + Double(fps) * 0.2)

        // スケール（Y方向ズーム込み）
        let zoomFactor   = SmartFramingAnalyzer.yZoomFactor
        let scale        = outputSize.height / inputSize.height * zoomFactor
        let scaledWidth  = inputSize.width  * scale
        let scaledHeight = inputSize.height * scale

        let minOffsetX    = -(scaledWidth  - outputSize.width)
        let minOffsetY    = -(scaledHeight - outputSize.height)
        let centerOffsetX = minOffsetX / 2
        let centerOffsetY = minOffsetY / 2

        // Step 1: 全フレームをスキャン（IOUトラッキング + 主役推定）
        let (rawPositions, finalDetectionInterval) = try await detectAllPositions(
            asset: asset,
            videoTrack: videoTrack,
            totalFrames: totalFrames,
            fps: Double(fps),
            progressHandler: { progressHandler($0 * 0.85) }
        )

        // Step 2: X・Y を別々に補間
        let rawX = rawPositions.map { $0.map { $0.x } }
        let rawY = rawPositions.map { $0.map { $0.y } }
        // shortGapFrames を検出間隔に依存させる（安定化のため）
        let shortGap = max(1, finalDetectionInterval * 2)
        let interpX = interpolate(rawX, fallback: 0.5, shortGapFrames: shortGap)
        let interpY = interpolate(rawY, fallback: 0.72, shortGapFrames: shortGap)

        // Step 3: EMA（指数移動平均）スムージング
        let smoothedX = emaSmooth(interpX, alpha: emaAlpha)
        let smoothedY = emaSmooth(interpY, alpha: emaAlpha)

        // Step 4X: X方向 ホールド＆フォロー（3秒ホールド、25%デッドゾーン）
        let minHoldFrames = Int(3.0 * Double(fps))
        let offsetsX = holdAndFollow(
            smoothedX,
            scaledDimension: scaledWidth,
            renderDimension: outputSize.width,
            minOffset: minOffsetX,
            centerOffset: centerOffsetX,
            targetRatio: 0.5,
            deadZoneRatio: 0.25,
            minHoldFrames: minHoldFrames,
            followFactor: followFactor
        )

        // Step 4Y: Y方向 ホールド＆フォロー（0.5秒ホールド、ヘッドルーム優先）
        let offsetsY = holdAndFollow(
            smoothedY,
            scaledDimension: scaledHeight,
            renderDimension: outputSize.height,
            minOffset: minOffsetY,
            centerOffset: centerOffsetY,
            targetRatio: 0.80,
            deadZoneRatio: 0.08,
            minHoldFrames: max(1, Int(0.5 * Double(fps))),
            followFactor: followFactor * 1.5
        )

        progressHandler(1.0)
        return zip(offsetsX, offsetsY).map { CGPoint(x: $0, y: $1) }
    }

    // MARK: - Step 1: IOUトラッキング付きフレームスキャン

    private func detectAllPositions(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        totalFrames: Int,
        fps: Double,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> ([CGPoint?], Int) {
        var result = [CGPoint?](repeating: nil, count: totalFrames)

        let tracker = PersonTracker()
        tracker.lifespanTarget = CGFloat(fps * 1.5)     // 1.5秒で主役と判定

        // ③ 適応的検出間隔: 動き大 → 4フレーム毎、安定 → 8フレーム毎
        var detectionInterval = 8
        var lastWeightedCenter: CGPoint? = nil
        var lastFilledIndex: Int = -1

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return (result, detectionInterval) }
        reader.add(output)
        reader.startReading()

        var frameIndex = 0
        while true {
            // autoreleasepool ensures CMSampleBuffer / CVPixelBuffer / Vision
            // intermediates are freed every iteration, preventing multi-GB
            // memory accumulation on long videos.
            let shouldBreak: Bool = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else {
                    return true  // end of stream
                }
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }

                if frameIndex % detectionInterval == 0,
                   frameIndex < totalFrames,
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {

                    let rawPersons = detectRawPersons(in: pixelBuffer)
                    let center = tracker.update(with: rawPersons)

                    // Fill any frames between lastFilledIndex and this sample with the
                    // last known weighted center (hold behavior). This avoids creating
                    // long linear interpolations across absent detections.
                    if lastFilledIndex + 1 <= frameIndex - 1 {
                        for fi in (lastFilledIndex + 1)..<frameIndex {
                            result[fi] = lastWeightedCenter
                        }
                    }

                    result[frameIndex] = center

                    // 適応的間隔: 前回中心との差が大きければ短縮
                    if let c = center, let lc = lastWeightedCenter {
                        let deviation = hypot(c.x - lc.x, c.y - lc.y)
                        detectionInterval = deviation > 0.10 ? 4 : 8
                    }

                    if let c = center { lastWeightedCenter = c }
                    lastFilledIndex = frameIndex
                }

                frameIndex += 1
                if frameIndex % 30 == 0 {
                    progressHandler(min(Double(frameIndex) / Double(totalFrames), 1.0))
                }
                return false
            }
            if shouldBreak { break }
        }

        // Trailing frames after lastFilledIndex: hold lastWeightedCenter
        if lastFilledIndex + 1 <= totalFrames - 1 {
            for fi in (lastFilledIndex + 1)..<totalFrames {
                result[fi] = lastWeightedCenter
            }
        }

        return (result, detectionInterval)
    }

    /// 1フレームから全ての人物を検出して返す（トラッカーに渡す生データ）
    private func detectRawPersons(in pixelBuffer: CVPixelBuffer) -> [RawPerson] {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest]) } catch { return [] }

        var persons: [RawPerson] = []

        // 人体ポーズ（優先）: 上半身キーポイントから中心・バウンディングを算出
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            for obs in bodyResults {
                guard let pts = try? obs.recognizedPoints(.all) else { continue }
                let upper = [pts[.neck], pts[.leftShoulder], pts[.rightShoulder],
                             pts[.nose], pts[.leftEar], pts[.rightEar],
                             pts[.leftWrist], pts[.rightWrist]]
                    .compactMap { $0 }.filter { $0.confidence > 0.25 }
                guard !upper.isEmpty else { continue }
                let xs = upper.map { $0.location.x }
                let ys = upper.map { $0.location.y }
                let cx = xs.reduce(0, +) / CGFloat(xs.count)
                let cy = ys.reduce(0, +) / CGFloat(ys.count)
                let bw = (xs.max()! - xs.min()!) + 0.05   // 少し余裕を持たせる
                let bh = (ys.max()! - ys.min()!) + 0.05
                let avgConf = upper.map { CGFloat($0.confidence) }.reduce(0, +) / CGFloat(upper.count)
                persons.append(RawPerson(x: cx, y: cy, w: bw, h: bh, confidence: avgConf))
            }
        }

        // 顔検出（ボディが1件も取れなかった場合のフォールバック）
        if persons.isEmpty, let faces = faceRequest.results, !faces.isEmpty {
            for face in faces {
                let bb = face.boundingBox
                persons.append(RawPerson(
                    x: bb.midX, y: bb.midY,
                    w: bb.width, h: bb.height,
                    confidence: CGFloat(face.confidence)
                ))
            }
        }

        return persons
    }

    // MARK: - Step 2: 線形補間

    private func interpolate(_ positions: [CGFloat?], fallback: CGFloat, shortGapFrames: Int = 8) -> [CGFloat] {
        let n = positions.count
        var result = [CGFloat](repeating: fallback, count: n)

        guard let firstKnown = positions.firstIndex(where: { $0 != nil }),
              let lastKnown  = positions.lastIndex(where:  { $0 != nil }) else {
            return result
        }

        // Leading: set to fallback (camera-centered) until first detection
        for i in 0..<firstKnown { result[i] = fallback }

        // Fill known value
        var prevIdx = firstKnown
        var prevVal = positions[firstKnown]!
        result[prevIdx] = prevVal

        var idx = firstKnown + 1
        while idx <= lastKnown {
            if let val = positions[idx] {
                let nextIdx = idx
                let nextVal = val
                let gap = nextIdx - prevIdx - 1

                if gap <= 0 {
                    // adjacent knowns
                } else if gap <= shortGapFrames {
                    // short gap -> linear interpolate between prevVal and nextVal
                    for j in 1...gap {
                        let t = CGFloat(j) / CGFloat(gap + 1)
                        result[prevIdx + j] = prevVal + (nextVal - prevVal) * t
                    }
                } else {
                    // long gap -> treat as disappearance: slowly return toward fallback
                    for j in 1...gap {
                        let t = CGFloat(j) / CGFloat(gap + 1)
                        result[prevIdx + j] = prevVal + (fallback - prevVal) * t
                    }
                }

                // set next known
                result[nextIdx] = nextVal
                prevIdx = nextIdx
                prevVal = nextVal
                idx = nextIdx + 1
            } else {
                idx += 1
            }
        }

        // Trailing: ease-out from lastKnown -> fallback so camera exits smoothly
        let trailing = n - 1 - lastKnown
        if trailing > 0 {
            for j in 1...trailing {
                let t = CGFloat(j) / CGFloat(trailing + 1)
                let eased = 1.0 - (1.0 - t) * (1.0 - t)   // ease-out
                result[lastKnown + j] = prevVal + (fallback - prevVal) * eased
            }
        }

        return result
    }

    // MARK: - Step 3: EMA（指数移動平均）スムージング
    //
    // y[n] = α·x[n] + (1-α)·y[n-1]
    //
    // 因果的（過去のみ参照）かつ IIR フィルタであるため:
    //  - 未来フレームを一切参照しない → 先読みパンが発生しない
    //  - 直近フレームに重みが集中し、過去は指数的に減衰 → カメラオペレーターの
    //    「今を最重視し、古い情報は忘れる」自然な反応モデルと一致
    //  - holdAndFollow (Step 4) も EMA 的追従であり、パイプライン全体で
    //    一貫した指数減衰モデルとなる
    //  - O(n) で計算可能（FIR の O(n×radius) より高速）
    //  - 無限インパルス応答 → 窓の打ち切りによる境界アーティファクトなし

    private func emaSmooth(_ values: [CGFloat], alpha: Double) -> [CGFloat] {
        let n = values.count
        guard n > 1 else { return values }

        var result = [CGFloat](repeating: 0, count: n)
        result[0] = values[0]

        let a = CGFloat(alpha)
        for i in 1..<n {
            result[i] = a * values[i] + (1.0 - a) * result[i - 1]
        }
        return result
    }

    // MARK: - Step 4: 汎用 ホールド＆フォロー

    /// - targetRatio: 被写体をレンダーフレーム内のどの位置（下から何割）に置くか
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
        var initialized  = false
        var followStartFrame = 0
        let warmupFrames = 15

        for i in 0..<positions.count {
            let personPos    = positions[i] * scaledDimension
            let targetOffset = max(minOffset, min(0, renderDimension * targetRatio - personPos))
            let deviation    = abs(targetOffset - cameraOffset)
            let holdElapsed  = i - settledFrame

            // 初期化: 最初のフレームではカメラを即座にターゲットへスナップし、
            // 以降は通常ホールド＆フォロー挙動とする（開幕のガクつき防止）
            if !initialized {
                cameraOffset = targetOffset
                initialized = true
                settledFrame = i
                offsets[i] = cameraOffset
                continue
            }

            if isFollowing {
                // Warmup ramp: on follow start the effective factor ramps from 0..followFactor
                // over `warmupFrames` frames to avoid a large immediate jump.
                let ramp = min(1.0, CGFloat(i - followStartFrame) / CGFloat(warmupFrames))
                let effectiveFactor = followFactor * ramp
                cameraOffset += (targetOffset - cameraOffset) * effectiveFactor
                if abs(targetOffset - cameraOffset) < 1.0 {
                    cameraOffset = targetOffset
                    isFollowing  = false
                    // Reset settledFrame on follow completion to start hold timer.
                    settledFrame = i
                }
            } else {
                if deviation > deadZone && holdElapsed >= minHoldFrames {
                    isFollowing = true
                    followStartFrame = i
                    // Do NOT move camera on the first follow frame; warmup will start next frame.
                }
            }

            offsets[i] = cameraOffset
        }
        return offsets
    }
}
