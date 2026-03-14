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
        let emaAlpha = 1.0 / (1.0 + Double(fps) * 0.14)

        // スケール（Y方向ズーム込み）
        let zoomFactor   = SmartFramingAnalyzer.yZoomFactor
        let scale        = outputSize.height / inputSize.height * zoomFactor
        let scaledWidth  = inputSize.width  * scale
        let scaledHeight = inputSize.height * scale

        let minOffsetX    = -(scaledWidth  - outputSize.width)
        let minOffsetY    = -(scaledHeight - outputSize.height)
        let centerOffsetX = minOffsetX / 2
        let centerOffsetY = minOffsetY / 2

        // Step 1: 全フレームをスキャン（IOUトラッキング + 主役推定 + ヒストグラム差分）
        let scan = try await detectAllPositions(
            asset: asset,
            videoTrack: videoTrack,
            totalFrames: totalFrames,
            fps: Double(fps),
            progressHandler: { progressHandler($0 * 0.85) }
        )

        // Step 2: X・Y を別々に補間
        let rawX = scan.positions.map { $0.map { $0.x } }
        let rawY = scan.positions.map { $0.map { $0.y } }
        // shortGapFrames を検出間隔に依存させる（安定化のため）
        let shortGap = max(1, scan.detectionInterval * 2)
        let interpX = interpolate(rawX, fallback: 0.5, shortGapFrames: shortGap)
        let interpY = interpolate(rawY, fallback: 0.72, shortGapFrames: shortGap)

        // Step 2.5: シーンカット検出（ヒストグラム AND 位置ジャンプの両方が一致した場合のみカット判定）
        // 仮EMAで位置データを安定化してから位置ジャンプを評価
        let prelimX = emaSmooth(interpX, alpha: emaAlpha)
        let prelimY = emaSmooth(interpY, alpha: emaAlpha)
        let cutFrames = detectCutFrames(
            histogramDiffs: scan.histogramDiffs,
            smoothedX: prelimX,
            smoothedY: prelimY,
            fps: Double(fps)
        )

        // Step 3: EMA（指数移動平均）スムージング — カットフレームでリセット
        let smoothedX = emaSmooth(interpX, alpha: emaAlpha, cutFrames: cutFrames)
        let smoothedY = emaSmooth(interpY, alpha: emaAlpha, cutFrames: cutFrames)

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
            followFactor: followFactor,
            cutFrames: cutFrames
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
            followFactor: followFactor * 1.5,
            cutFrames: cutFrames
        )

        progressHandler(1.0)
        return zip(offsetsX, offsetsY).map { CGPoint(x: $0, y: $1) }
    }

    // MARK: - Step 1: IOUトラッキング付きフレームスキャン

    /// 解析結果: 人物位置 + ヒストグラム差分（カット検出用）
    private struct ScanResult {
        var positions: [CGPoint?]
        var detectionInterval: Int
        /// フレーム間のヒストグラム差分 (chi-squared distance)。index i = フレーム i と i-1 の差。
        var histogramDiffs: [CGFloat]
    }

    private func detectAllPositions(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        totalFrames: Int,
        fps: Double,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> ScanResult {
        var result = [CGPoint?](repeating: nil, count: totalFrames)
        var histDiffs = [CGFloat](repeating: 0, count: totalFrames)

        let tracker = PersonTracker()
        tracker.lifespanTarget = CGFloat(fps * 1.5)     // 1.5秒で主役と判定

        // ③ 適応的検出間隔: 動き大 → 4フレーム毎、安定 → 8フレーム毎
        var detectionInterval = 8
        var lastWeightedCenter: CGPoint? = nil
        var lastFilledIndex: Int = -1

        // ヒストグラム用: 前フレームのヒストグラムを保持
        var prevHistogram: [CGFloat]? = nil

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return ScanResult(positions: result, detectionInterval: detectionInterval, histogramDiffs: histDiffs)
        }
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

                if frameIndex < totalFrames,
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {

                    // ヒストグラム差分: 毎フレーム計算（カット位置を正確に特定するため）
                    let hist = Self.computeHistogram(pixelBuffer)
                    if let prev = prevHistogram {
                        histDiffs[frameIndex] = Self.chiSquaredDistance(prev, hist)
                    }
                    prevHistogram = hist

                    // 人物検出: detectionInterval毎
                    if frameIndex % detectionInterval == 0 {
                        let rawPersons = detectRawPersons(in: pixelBuffer)
                        let center = tracker.update(with: rawPersons)

                        // Fill any frames between lastFilledIndex and this sample with the
                        // last known weighted center (hold behavior).
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

        return ScanResult(positions: result, detectionInterval: detectionInterval, histogramDiffs: histDiffs)
    }

    // MARK: - Histogram Helpers

    /// BGRA ピクセルバッファから HSV ヒストグラム (H:32 × S:16 × V:16 = 64要素) を計算。
    /// HSV空間は照明変化に頑健で、RGB空間よりカット検出の誤検出が少ない。
    /// (参考: "Shot Boundary Detection Algorithm Based on HSV Histogram and HOG Feature")
    /// 8ピクセル間隔でサンプリング → フルHDでも ~32000 サンプルで高速。
    private static func computeHistogram(_ pixelBuffer: CVPixelBuffer) -> [CGFloat] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let hBins = 32
        let sBins = 16
        let vBins = 16
        let totalBins = hBins + sBins + vBins  // 64
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [CGFloat](repeating: 0, count: totalBins)
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var hist = [CGFloat](repeating: 0, count: totalBins)
        let step = 8
        var count: CGFloat = 0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * 4
                let b = CGFloat(ptr[offset]) / 255.0
                let g = CGFloat(ptr[offset + 1]) / 255.0
                let r = CGFloat(ptr[offset + 2]) / 255.0

                // RGB → HSV (整数化不使用、直接浮動小数点)
                let cMax = max(r, max(g, b))
                let cMin = min(r, min(g, b))
                let delta = cMax - cMin

                let h: CGFloat  // 0..360
                if delta < 0.001 {
                    h = 0
                } else if cMax == r {
                    h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if cMax == g {
                    h = 60.0 * ((b - r) / delta + 2)
                } else {
                    h = 60.0 * ((r - g) / delta + 4)
                }
                let hNorm = ((h < 0 ? h + 360 : h) / 360.0)  // 0..1
                let s = cMax > 0 ? delta / cMax : 0            // 0..1
                let v = cMax                                    // 0..1

                let hIdx = min(hBins - 1, Int(hNorm * CGFloat(hBins)))
                let sIdx = min(sBins - 1, Int(s * CGFloat(sBins)))
                let vIdx = min(vBins - 1, Int(v * CGFloat(vBins)))

                hist[hIdx] += 1
                hist[hBins + sIdx] += 1
                hist[hBins + sBins + vIdx] += 1
                count += 1
                x += step
            }
            y += step
        }

        // 正規化
        if count > 0 {
            for i in 0..<hist.count { hist[i] /= count }
        }
        return hist
    }

    /// 2つのヒストグラム間の chi-squared distance。
    /// 値が大きいほど画像の色分布が異なる（= シーンカットの可能性が高い）。
    private static func chiSquaredDistance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 0..<min(a.count, b.count) {
            let diff = a[i] - b[i]
            let denom = a[i] + b[i]
            if denom > 0 {
                sum += (diff * diff) / denom
            }
        }
        return sum
    }

    /// 1フレームから全ての人物を検出して返す（トラッカーに渡す生データ）
    private func detectRawPersons(in pixelBuffer: CVPixelBuffer) -> [RawPerson] {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRectRequest = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([bodyRequest, faceRequest, bodyRectRequest]) } catch { return [] }

        var persons: [RawPerson] = []

        // 人体ポーズ（優先）: 上半身キーポイントから加重中心・バウンディングを算出
        // 目・鼻は顔の正面方向を表すため重みを高く、耳・手首は補助的
        if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
            for obs in bodyResults {
                guard let pts = try? obs.recognizedPoints(.all) else { continue }
                let keyWeights: [(VNHumanBodyPoseObservation.JointName, CGFloat)] = [
                    (.nose, 3.0),
                    (.leftEye, 2.5), (.rightEye, 2.5),
                    (.neck, 1.5),
                    (.leftShoulder, 1.0), (.rightShoulder, 1.0),
                    (.leftEar, 0), (.rightEar, 0),
                    (.leftWrist, 0.3), (.rightWrist, 0.3),
                ]
                var weightedX: CGFloat = 0
                var weightedY: CGFloat = 0
                var totalWeight: CGFloat = 0
                var allXs: [CGFloat] = []
                var allYs: [CGFloat] = []
                var confSum: CGFloat = 0
                var confCount: CGFloat = 0

                for (joint, weight) in keyWeights {
                    guard let pt = pts[joint], pt.confidence > 0.25 else { continue }
                    let loc = pt.location
                    weightedX += loc.x * weight
                    weightedY += loc.y * weight
                    totalWeight += weight
                    allXs.append(loc.x)
                    allYs.append(loc.y)
                    confSum += CGFloat(pt.confidence)
                    confCount += 1
                }
                guard totalWeight > 0, !allXs.isEmpty else { continue }
                let cx = weightedX / totalWeight
                let cy = weightedY / totalWeight
                let bw = (allXs.max()! - allXs.min()!) + 0.05
                let bh = (allYs.max()! - allYs.min()!) + 0.05
                let avgConf = confSum / confCount
                persons.append(RawPerson(x: cx, y: cy, w: bw, h: bh, confidence: avgConf))
            }
        }

        // 人物矩形検出（BodyPoseが取れない後ろ姿・遠景のフォールバック）
        // BodyPoseで既に検出された人物と重なる矩形はスキップ
        if let rectResults = bodyRectRequest.results, !rectResults.isEmpty {
            for obs in rectResults {
                let bb = obs.boundingBox
                let cx = bb.midX
                let cy = bb.midY
                // 既存のBodyPose検出と重複チェック（IOU簡易版）
                let alreadyDetected = persons.contains { p in
                    let overlapX = abs(p.x - cx) < (p.w + bb.width) / 2
                    let overlapY = abs(p.y - cy) < (p.h + bb.height) / 2
                    return overlapX && overlapY
                }
                if !alreadyDetected {
                    persons.append(RawPerson(
                        x: cx, y: cy,
                        w: bb.width, h: bb.height,
                        confidence: CGFloat(obs.confidence) * 0.8  // BodyPoseより少し低い信頼度
                    ))
                }
            }
        }

        // 顔検出（ボディもシルエットも取れなかった場合のフォールバック）
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

    // MARK: - Step 2.5: シーンカット検出（ヒストグラム + 位置ジャンプ AND方式）

    /// ヒストグラム差分と位置ジャンプの両方が検出されたフレームだけをカットと判定。
    ///
    /// 改善点（論文ベース）:
    /// - HSVヒストグラム: 照明変化に頑健
    /// - スライディングウィンドウ適応的閾値: 局所的な映像特性に追従
    ///   (参考: "Video Shot Boundary Detection Using Relative Difference Between Frames")
    /// - フラッシュ除去（2次微分）: カメラフラッシュの誤検出を排除
    ///   (参考: "Shot Detection Using Pixel Difference and Color Histogram")
    /// - 位置ジャンプAND条件: 人物移動のみの偽陽性を排除
    private func detectCutFrames(
        histogramDiffs: [CGFloat],
        smoothedX: [CGFloat],
        smoothedY: [CGFloat],
        fps: Double
    ) -> Set<Int> {
        var cuts = Set<Int>()
        let n = histogramDiffs.count
        guard n > 1, smoothedX.count == n, smoothedY.count == n else { return cuts }

        // --- ヒストグラム候補（スライディングウィンドウ適応的閾値） ---
        // 局所的な統計量に基づく閾値で、映像の特性変化に追従する
        let windowRadius = max(15, Int(fps * 1.0))  // ±1秒のウィンドウ
        let multiplier: CGFloat = 4.0  // 局所平均の何倍でカット判定

        // グローバル最低閾値（非常に静かな映像でもノイズを拾わない）
        let sorted = histogramDiffs.filter { $0 > 0 }.sorted()
        let globalFloor: CGFloat = sorted.isEmpty ? 0.3 : max(0.15, sorted[min(sorted.count - 1, sorted.count * 95 / 100)])

        var histCandidates: [(index: Int, score: CGFloat)] = []
        for i in 1..<n {
            let diff = histogramDiffs[i]
            // 局所ウィンドウの平均・標準偏差を計算
            let wStart = max(0, i - windowRadius)
            let wEnd = min(n, i + windowRadius + 1)
            var sum: CGFloat = 0
            var sumSq: CGFloat = 0
            var wCount: CGFloat = 0
            for j in wStart..<wEnd {
                // 候補フレーム自身は局所統計から除外（自分でスパイクを作らない）
                if j == i { continue }
                sum += histogramDiffs[j]
                sumSq += histogramDiffs[j] * histogramDiffs[j]
                wCount += 1
            }
            guard wCount > 0 else { continue }
            let localMean = sum / wCount
            let localStd = sqrt(max(0, sumSq / wCount - localMean * localMean))
            // 閾値: max(グローバル最低閾値, 局所平均 + multiplier × 局所標準偏差)
            let adaptiveThreshold = max(globalFloor, localMean + multiplier * localStd)

            if diff > adaptiveThreshold {
                histCandidates.append((i, diff))
            }
        }

        // --- フラッシュ除去（2次微分チェック） ---
        // フラッシュ: フレーム i で急上昇し i+1 で急降下 → 2次微分が大きな負値
        // 本物のカット: i で上昇しその後は安定 → 2次微分は小さい
        var flashFiltered: [(index: Int, score: CGFloat)] = []
        for candidate in histCandidates {
            let i = candidate.index
            if i + 1 < n {
                let d2 = histogramDiffs[i + 1] - histogramDiffs[i]  // 差分の差分
                // フラッシュ: 直後にほぼ同等の差分が出る（元に戻る）
                if histogramDiffs[i + 1] > candidate.score * 0.5 && d2 < 0 {
                    NSLog("SmartFramingAnalyzer: rejected flash at frame %d (diff=%.4f, next=%.4f)",
                          i, candidate.score, histogramDiffs[i + 1])
                    continue
                }
            }
            flashFiltered.append(candidate)
        }

        let histSet = Set(flashFiltered.map { $0.index })
        guard !histSet.isEmpty else { return cuts }
        NSLog("SmartFramingAnalyzer: histogram candidates=%d (after flash filter, globalFloor=%.4f)",
              histSet.count, globalFloor)

        // --- 位置ジャンプ候補 ---
        let w = max(6, Int(fps * 0.5))
        var cumX = [CGFloat](repeating: 0, count: n + 1)
        var cumY = [CGFloat](repeating: 0, count: n + 1)
        for i in 0..<n {
            cumX[i + 1] = cumX[i] + smoothedX[i]
            cumY[i + 1] = cumY[i] + smoothedY[i]
        }
        func windowMean(_ cum: [CGFloat], _ start: Int, _ end: Int) -> CGFloat {
            let len = CGFloat(end - start)
            return len > 0 ? (cum[end] - cum[start]) / len : 0
        }

        let posThreshold: CGFloat = 0.15
        var posCandidates = Set<Int>()
        for i in w..<(n - w) {
            let preX = windowMean(cumX, i - w, i)
            let preY = windowMean(cumY, i - w, i)
            let postX = windowMean(cumX, i, i + w)
            let postY = windowMean(cumY, i, i + w)
            let d = hypot(postX - preX, postY - preY)
            if d > posThreshold {
                posCandidates.insert(i)
            }
        }

        // --- AND: ヒストグラム候補の近傍に位置候補がある場合のみ ---
        let mergeRadius = max(4, Int(fps * 0.3))
        var confirmed: [(index: Int, histScore: CGFloat)] = []
        for item in flashFiltered {
            var hasPosMatch = false
            for offset in -mergeRadius...mergeRadius {
                if posCandidates.contains(item.index + offset) {
                    hasPosMatch = true
                    break
                }
            }
            if hasPosMatch {
                confirmed.append((item.index, item.score))
            } else {
                NSLog("SmartFramingAnalyzer: rejected hist candidate frame %d (no position jump nearby)",
                      item.index)
            }
        }

        // 近接統合
        let mergeWindow = max(4, Int(fps * 0.5))
        var i = 0
        while i < confirmed.count {
            var bestIdx = i
            var bestScore = confirmed[i].histScore
            var j = i + 1
            while j < confirmed.count && confirmed[j].index - confirmed[i].index < mergeWindow {
                if confirmed[j].histScore > bestScore {
                    bestScore = confirmed[j].histScore
                    bestIdx = j
                }
                j += 1
            }
            cuts.insert(confirmed[bestIdx].index)
            NSLog("SmartFramingAnalyzer: confirmed cut at frame %d (chi²=%.4f)",
                  confirmed[bestIdx].index, bestScore)
            i = j
        }

        if !cuts.isEmpty {
            NSLog("SmartFramingAnalyzer: total %d confirmed scene cut(s)", cuts.count)
        }
        return cuts
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

    private func emaSmooth(_ values: [CGFloat], alpha: Double, cutFrames: Set<Int> = []) -> [CGFloat] {
        let n = values.count
        guard n > 1 else { return values }

        var result = [CGFloat](repeating: 0, count: n)
        result[0] = values[0]

        let a = CGFloat(alpha)
        for i in 1..<n {
            if cutFrames.contains(i) {
                // カットフレームではEMAをリセット — 旧シーンの値を引きずらない
                result[i] = values[i]
            } else {
                result[i] = a * values[i] + (1.0 - a) * result[i - 1]
            }
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
        followFactor: CGFloat,
        cutFrames: Set<Int> = []
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

            // シーンカット: 新シーンの被写体位置に即座にスナップ
            // ホールドタイマー・フォロー状態もリセットし、新シーンを基準に再開
            if cutFrames.contains(i) {
                cameraOffset = targetOffset
                settledFrame = i
                isFollowing = false
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
