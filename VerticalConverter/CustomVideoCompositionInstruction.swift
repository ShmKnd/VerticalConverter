//
//  CustomVideoCompositionInstruction.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import AVFoundation

class CustomVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    
    // スマートフレーミング設定
    var smartFramingEnabled: Bool
    var dampingFactor: Double
    var inputSize: CGSize

    /// 事前解析済みオフセット配列（nil = リアルタイムフォールバック）
    /// 各要素: .x = 横オフセット（ピクセル）, .y = 縦オフセット（ピクセル）
    var precomputedOffsets: [CGPoint]?

    // レイヤーインストラクション
    var layerInstructions: [AVVideoCompositionLayerInstruction]
    
    // レターボックスの表示モード
    enum LetterboxMode: Int, CaseIterable {
        case fitWidth = 0           // 既存の幅に合わせるモード
        case centerSquare = 1       // 中央を正方形にトリミングして表示
        case centerPortrait4x3 = 2  // 中央を縦4:横3にトリミングして表示

        var displayName: String {
            switch self {
            case .fitWidth: return "幅に合わせる"
            case .centerSquare: return "中央を正方形"
            case .centerPortrait4x3: return "中央を縦4:横3"
            }
        }
    }
    var letterboxMode: LetterboxMode = .fitWidth
    
    init(
        timeRange: CMTimeRange,
        layerInstructions: [AVVideoCompositionLayerInstruction],
        smartFramingEnabled: Bool,
        dampingFactor: Double,
        inputSize: CGSize,
        precomputedOffsets: [CGPoint]? = nil
    ) {
        self.timeRange = timeRange
        self.layerInstructions = layerInstructions
        self.smartFramingEnabled = smartFramingEnabled
        self.dampingFactor = dampingFactor
        self.inputSize = inputSize
        self.precomputedOffsets = precomputedOffsets
        self.letterboxMode = .fitWidth
        
        // requiredSourceTrackIDsを設定
        if let trackID = layerInstructions.first?.trackID {
            self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        }
        
        super.init()
    }
}
