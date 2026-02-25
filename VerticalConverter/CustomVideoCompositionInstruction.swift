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
    
    // レイヤーインストラクション
    var layerInstructions: [AVVideoCompositionLayerInstruction]
    
    init(
        timeRange: CMTimeRange,
        layerInstructions: [AVVideoCompositionLayerInstruction],
        smartFramingEnabled: Bool,
        dampingFactor: Double,
        inputSize: CGSize
    ) {
        self.timeRange = timeRange
        self.layerInstructions = layerInstructions
        self.smartFramingEnabled = smartFramingEnabled
        self.dampingFactor = dampingFactor
        self.inputSize = inputSize
        
        // requiredSourceTrackIDsを設定
        if let trackID = layerInstructions.first?.trackID {
            self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        }
        
        super.init()
    }
}
