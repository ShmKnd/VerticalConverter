//
//  CustomVideoCompositionInstruction.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

@preconcurrency import AVFoundation

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
        case centerPortrait3x4 = 3  // 中央を縦3:横4にトリミングして表示

        var displayName: String {
            switch self {
            case .fitWidth: return "Fit Width"
            case .centerSquare: return "Center Square"
            case .centerPortrait4x3: return "Portrait 4x3"
            case .centerPortrait3x4: return "Portrait 3x4"
            }
        }
    }

    // HDR -> SDR 変換設定
    enum HDRTarget: Int {
        case sRGB = 0
        case rec709 = 1
    }

    /// トーンマッピングのスタイル
    enum ToneMappingMode: Int, CaseIterable {
        case natural  = 0   // ニュートラル（Rec.709/sRGB に忠実な自然な色）
        case cinematic = 1  // シネマティック（ACES / Apple Headroom – コントラスト高め）

        var displayName: String {
            switch self {
            case .natural:   return "Natural"
            case .cinematic: return "Cinematic"
            }
        }
    }
    var hdrConversionEnabled: Bool = false
    var toneMappingMode: ToneMappingMode = .natural
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
