//
//  DockProgress.swift
//  VerticalConverter
//
//  Dockアイコンに処理中インジケータとプログレスバーを表示する
//

import AppKit

@MainActor
enum DockProgress {

    private static let tileSize: CGFloat = 128
    private static var progressView: DockProgressView?

    static func start() {
        let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        view.progress = 0
        progressView = view
        NSApp.dockTile.contentView = view
        NSApp.dockTile.display()
    }

    static func update(_ value: Double) {
        progressView?.progress = value
        NSApp.dockTile.display()
    }

    static func stop() {
        progressView = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }
}

// MARK: - Dock上に描画するカスタムビュー

private class DockProgressView: NSView {

    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size

        // アプリアイコンを描画
        if let appIcon = NSApp.applicationIconImage {
            appIcon.draw(in: bounds)
        } else {
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        }

        // プログレスバー（アイコン下部に重ねる・黒背景なし）
        let barMargin: CGFloat = size.width * 0.08
        let barHeight: CGFloat = size.height * 0.09
        let barY: CGFloat = size.height * 0.05
        let barWidth = size.width - barMargin * 2
        let barX = barMargin

        // バー背景（半透明黒・角丸）
        let bgRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        bgPath.fill()

        // バー本体（白・角丸）
        let fillWidth = barWidth * CGFloat(max(0, min(1, progress)))
        if fillWidth > 0 {
            let fillRect = CGRect(x: barX, y: barY, width: fillWidth, height: barHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.white.setFill()
            fillPath.fill()
        }

    }
}
