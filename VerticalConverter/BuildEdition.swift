//
//  BuildEdition.swift
//  VerticalConverter
//
//  Build Configuration で切り替わるエディション定義。
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS に設定されたフラグで分岐する。
//
//    - EDITION_DIRECT   : 直販版 (MIT + Commons Clause)
//    - EDITION_DEMO     : デモ版 (起動後24時間以内は5回までフル機能、以降ウォーターマーク)
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

    /// デモ版でウォーターマークを表示すべきかどうか。
    /// 起動後24時間以内かつ5回未満のエンコードならウォーターマークなし。
    var showsWatermark: Bool {
        guard self == .demo else { return false }
        return !DemoUsageTracker.shared.hasRemainingFreeEncodes
    }

    /// 表示用ラベル
    var displayName: String {
        switch self {
        case .direct:   return "Direct"
        case .demo:     return "Demo"
        case .appStore: return "App Store"
        }
    }
}

// MARK: - Demo Usage Tracker

/// デモ版の使用回数と24時間制限を管理する。
/// 24時間ごとにエンコード回数がリセットされ、各期間で5回までフル機能で利用可能。
final class DemoUsageTracker {
    static let shared = DemoUsageTracker()

    private let windowStartKey = "DemoWindowStartDate"
    private let encodeCountKey = "DemoEncodeCount"
    private static let maxFreeEncodes = 5
    private static let windowDuration: TimeInterval = 24 * 60 * 60 // 24時間

    private init() {
        // 初回起動時にウィンドウ開始日を記録
        if UserDefaults.standard.object(forKey: windowStartKey) == nil {
            UserDefaults.standard.set(Date(), forKey: windowStartKey)
        }
    }

    /// 現在のウィンドウ開始日時
    private var windowStartDate: Date {
        UserDefaults.standard.object(forKey: windowStartKey) as? Date ?? Date()
    }

    /// 24時間経過していたらウィンドウとカウントをリセットする
    private func resetWindowIfNeeded() {
        if Date().timeIntervalSince(windowStartDate) >= Self.windowDuration {
            UserDefaults.standard.set(Date(), forKey: windowStartKey)
            UserDefaults.standard.set(0, forKey: encodeCountKey)
        }
    }

    /// 現ウィンドウ内のエンコード回数
    var encodeCount: Int {
        resetWindowIfNeeded()
        return UserDefaults.standard.integer(forKey: encodeCountKey)
    }

    /// フリーエンコード残り回数
    var remainingFreeEncodes: Int {
        resetWindowIfNeeded()
        return max(Self.maxFreeEncodes - UserDefaults.standard.integer(forKey: encodeCountKey), 0)
    }

    /// フリーエンコードがまだ残っているか
    var hasRemainingFreeEncodes: Bool {
        remainingFreeEncodes > 0
    }

    /// エンコード成功時にカウントをインクリメントする
    func recordEncode() {
        resetWindowIfNeeded()
        let current = UserDefaults.standard.integer(forKey: encodeCountKey)
        UserDefaults.standard.set(current + 1, forKey: encodeCountKey)
    }
}
