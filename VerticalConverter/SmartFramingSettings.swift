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
        case fast = "Fast"
        case normal = "Normal"
        case slow = "Slow"
        
        var dampingFactor: Double {
            switch self {
            case .fast: return 0.3
            case .normal: return 0.15
            case .slow: return 0.08
            }
        }
    }
}
