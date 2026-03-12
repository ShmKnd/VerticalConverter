//
//  BuildEdition.swift
//  VerticalConverter
//
//  Build Configuration で切り替わるエディション定義。
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS に設定されたフラグで分岐する。
//
//    - EDITION_DIRECT   : 直販版 (MIT + Commons Clause)
//    - EDITION_DEMO     : デモ版 (ウォーターマーク付き)
//    - EDITION_APPSTORE : App Store 版 (サンドボックス有効)
//

import Foundation

enum BuildEdition {
    case direct
    case demo
    case appStore

    static let current: BuildEdition = {
        #if EDITION_DEMO
        return .demo
        #elseif EDITION_APPSTORE
        return .appStore
        #else
        return .direct
        #endif
    }()

    /// デモ版のみウォーターマークを表示する
    var showsWatermark: Bool { self == .demo }

    /// 表示用ラベル
    var displayName: String {
        switch self {
        case .direct:   return "Direct"
        case .demo:     return "Demo"
        case .appStore: return "App Store"
        }
    }
}
