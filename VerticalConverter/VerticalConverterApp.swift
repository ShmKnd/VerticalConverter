//
//  VerticalConverterApp.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
import AppKit

@main
struct VerticalConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Vertical Converter") {
                    let html = """
                    <html><body style="font-family:-apple-system;font-size:11px;text-align:center;color:#888">
                    <p style="margin:4px 0">
                    <a href="https://github.com/ShmKnd">GitHub</a>
                    &nbsp;·&nbsp;
                    <a href="https://x.com/SHunO_106">X (Twitter)</a>
                    </p>
                    <p style="margin:8px 0 2px;font-size:10px;color:#aaa">
                    MIT License + Commons Clause &copy; 2026 shoma<br>
                    This software may not be sold.<br>
                    See LICENSE for details.
                    </p>
                    </body></html>
                    """
                    let credits = NSAttributedString(
                        html: Data(html.utf8),
                        options: [.documentType: NSAttributedString.DocumentType.html,
                                  .characterEncoding: String.Encoding.utf8.rawValue as NSNumber],
                        documentAttributes: nil
                    ) ?? NSAttributedString(string: "")
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Vertical Converter",
                        .credits: credits
                    ])
                }
            }
        }
    }
}
