//
//  SmartFramingSettings.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import Foundation

struct SmartFramingSettings {
    var enabled: Bool = false
    var smoothness: Smoothness = .normal
    
    enum Smoothness: String, CaseIterable {
        case fast   = "Fast"
        case normal = "Normal"
        case slow   = "Slow"
        
        var dampingFactor: Double {
            switch self {
            case .fast:   return 0.12
            case .normal: return 0.06
            case .slow:   return 0.03
            }
        }

        /// 2パス解析時のパン追従速度 (holdAndFollowの followFactor)
        var followFactor: Double {
            switch self {
            case .fast:   return 0.12   // 約30fps×8弔0.8秒で到達
            case .normal: return 0.06   // 約30fps×16弔1.5秒で到達
            case .slow:   return 0.03   // 約30fps×32弔3秒で到達
            }
        }
    }
}
