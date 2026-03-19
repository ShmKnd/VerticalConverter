//
//  VerticalConverterApp.swift
//  VerticalConverter
//
//  Created on 2026/02/25.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct VerticalConverterApp: App {
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Vertical Converter") {
                    AboutWindowController.shared.show()
                }
            }
        }
#endif
    }
}

// MARK: - Custom About Window
#if os(macOS)
private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = NSHostingView(rootView: AboutView())
        aboutView.frame = NSRect(x: 0, y: 0, width: 360, height: 520)

        let w = NSWindow(
            contentRect: aboutView.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.center()
        w.contentView = aboutView
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }
}

private struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            // App Icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Spacer().frame(height: 12)

            Text("Vertical Converter")
                .font(.title2.bold())

            Text("The smart landscape-to-portrait video converter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("Version \(version) (\(build))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer().frame(height: 16)

            // Links
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/ShmKnd/VerticalConverter")!)
                Text("·").foregroundStyle(.secondary)
                Link("X (Twitter)", destination: URL(string: "https://x.com/SHunO_106")!)
            }
            .font(.caption)

            Spacer().frame(height: 20)

            // License
            ScrollView {
                Text(Self.licenseText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 240)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 20)

            Spacer().frame(height: 16)

            Text("© 2026 shoma")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 16)
        }
        .frame(width: 360, height: 520)
    }

    private static let licenseText: String = {
    #if EDITION_APPSTORE
    return """
    MIT License

    Copyright (c) 2026 shoma

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    ---

    The source code of this application is available on GitHub under MIT License + Commons Clause. The Commons Clause condition applies to the source code only and does not restrict your use of this app.

    https://github.com/ShmKnd/VerticalConverter
    """
    #else
    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
       let text = try? String(contentsOf: url) {
        return normalizeLicense(text)
    }
    // フォールバック: ハードコード（LICENSEファイルが読めない場合）
    return normalizeLicense("""
    MIT License

    Copyright (c) 2026 shoma

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    ---

    Commons Clause License Condition v1.0

    The Software is provided to you by the Licensor under the License, as defined below, subject to the following condition.

    Without limiting other conditions in the License, the grant of rights under the License will not include, and the License does not grant to you, the right to Sell the Software.

    For purposes of the foregoing, "Sell" means practicing any or all of the rights granted to you under the License to provide to third parties, for a fee or other consideration (including without limitation fees for hosting or consulting/support services related to the Software), a product or service whose value derives, entirely or substantially, from the functionality of the Software. Any license notice or attribution required by the License must also include this Commons Clause License Condition notice.

    Software: Vertical Converter
    License: MIT
    Licensor: shoma
    """)
    #endif
}()

private static func normalizeLicense(_ text: String) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")
    return paragraphs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  .replacingOccurrences(of: "\n", with: " ") }
        .joined(separator: "\n\n")
}

}

#endif

