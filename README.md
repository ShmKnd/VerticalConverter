<h1 align="center">Vertical Converter</h1>

<p align="center">
  <b>16:9 横長動画 → 9:16 縦型動画に変換する macOS ネイティブアプリ</b><br>
  YouTube ショート / Instagram リール / TikTok 向け
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon-black?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT%20%2B%20Commons%20Clause-green?style=flat-square" alt="License">
</p>

<p align="center">
  <img src="VC_demoGIF.gif" alt="Vertical Converter デモ" width="720">
</p>

<p align="center">
  <a href="https://youtu.be/TacC07xiaG8">
    <img src="https://img.shields.io/badge/▶_YouTube-解説動画を見る-red?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube 解説動画">
  </a>
  &nbsp;
  <a href="https://ko-fi.com/ShmKnd">
    <img src="https://img.shields.io/badge/☕_Ko--fi-Support-ff5e5b?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Ko-fi">
  </a>
</p>

<p align="center">
  <a href="#english">📖 English</a>&nbsp;&nbsp;|&nbsp;&nbsp;<a href="#日本語">📖 日本語</a>
</p>

---

<h2 id="english">English</h2>

## Screenshots

<p align="center">
  <img src="VC_SS-1.jpg" alt="Main Screen" width="48%">&nbsp;&nbsp;
  <img src="VC_SS-2.jpg" alt="Settings & Conversion" width="48%">
</p>

---

## Features

### 🎬 Conversion & Cropping

- **Drag & Drop** — Just drop files onto the window (multiple files supported)
- **Batch Conversion** — Select multiple files and convert them sequentially
- **5 Crop Modes** — Fit W / Fit H / Square / 4:3 / 3:4
- **Crop Preview** — Preview crop results with thumbnail timeline seeking

### 🧠 Smart Framing

- **Vision Person Tracking** — Analyzes all frames and automatically follows the subject while cropping vertically
- **IOU Tracking** — Tracks multiple people individually and auto-estimates the main subject (longest duration, most stable)
- **Y-axis Headroom** — Automatically maintains head space even for dance/talk videos
- **Follow Speed** — Choose from 3 levels: Fast / Normal / Slow

### 🎨 HDR Support

- **HDR → SDR Conversion** — Natural / Cinematic tone mapping
- **HDR Passthrough** — Vertical conversion while preserving HLG/PQ/BT.2020 metadata

### ⚙️ Encoding Settings

| Setting | Options |
|:--|:--|
| Codec | H.264 / H.265 / H.264 (VT) / H.265 (VT) / ProRes422 (VT) |
| Container | MOV / MP4 (HEVC only) |
| Resolution | 720p (720×1280) / 1080p (1080×1920) |
| Frame Rate | Src (preserve source) / 24 / 29.97 DF / 30 / 60 fps |
| Bitrate | 8 / 10 / 12 Mbps |
| Bitrate Mode | VBR / CBR / ABR |

### 🛡️ Automatic Input Handling

- **hev1 → hvc1 Auto-Remux** (no re-encoding, no quality loss)
- **DNxHD/DNxHR Input** — Early detection with error feedback
- **Dock Progress Bar** — Shows conversion progress in the Dock

### 💻 UI / UX

- **Output Folder Selection** — Specify output directory via NSOpenPanel for all editions (reset button restores "Same as Input")
- **Setting Tooltips** — Hover over each setting row for an English description
- **GUI Lock During Encoding** — Drop zone and setting panels are disabled during conversion (Cancel remains active)
- **Completion Sound** — Plays macOS system sound (Glass) when encoding finishes
- **About Window** — Custom borderless window with app icon, tagline, GitHub/X links, and full license text from "About Vertical Converter" in the menu bar
- **Version Display** — App version shown below the header

---

## Technical Specs

| Item | Details |
|:--|:--|
| Supported OS | macOS 13.0+ (Apple Silicon only). HDR features require macOS 14+ |
| Language | Swift / SwiftUI |
| Frameworks | AVFoundation, Vision, Core Image, VideoToolbox |
| Processing | 2-pass (analysis → conversion). 1-pass when Smart Framing is OFF |
| Output Format | MP4 (H.264 + AAC 192kbps) / MOV・MP4 (H.265 + AAC) / MOV (ProRes422) |
| Output Resolution | 720×1280 or 1080×1920 (9:16) |

---

## Build

```bash
cd VerticalConverter
open VerticalConverter.xcodeproj
```

Select a Scheme in Xcode, then ⌘+B (build) or ⌘+R (run).

### Edition Build Configurations

All editions share a single source base. Editions are differentiated by `SWIFT_ACTIVE_COMPILATION_CONDITIONS` with `#if` branching.

| Scheme | Debug / Release Config | Flag | Description |
|:--|:--|:--|:--|
| **VerticalConverter (Direct)** | Debug / Release | `EDITION_DIRECT` | Direct distribution. No sandbox. MIT + Commons Clause |
| **VerticalConverter (Demo)** | Debug Demo / Release Demo | `EDITION_DEMO` | Demo version. First 5 encodes per 24h are full quality; watermark after limit. DEMO badge in UI |
| **VerticalConverter (AppStore)** | Debug AppStore / Release AppStore | `EDITION_APPSTORE` | App Store version. App Sandbox enabled |

#### Entitlements

| Edition | File | App Sandbox |
|:--|:--|:--|
| Direct / Demo | `VerticalConverter.entitlements` | Disabled |
| AppStore | `VerticalConverter_AppStore.entitlements` | **Enabled** + `files.user-selected.read-write` |

#### Command Line Build

```bash
# Direct
xcodebuild -scheme "VerticalConverter (Direct)" -configuration Release build

# Demo
xcodebuild -scheme "VerticalConverter (Demo)" -configuration "Release Demo" build

# App Store
xcodebuild -scheme "VerticalConverter (AppStore)" -configuration "Release AppStore" build
```

---

## Usage

1. Drag video files onto the window (multiple files supported), or click to select
2. Configure resolution, FPS, codec, bitrate, and crop mode
3. Optionally use **Preview** to check crop results
4. Optionally enable **Smart Framing** / **HDR→SDR conversion**
5. Click **Start Conversion**
6. When complete, the output folder opens automatically in Finder

---

## Project Structure

```
VerticalConverter/
├── VerticalConverterApp.swift              # Entry point
├── BuildEdition.swift                      # Edition definitions (#if branching for Direct/Demo/AppStore)
├── ContentView.swift                       # Main UI + ContentViewModel (batch support)
├── VideoProcessor.swift                    # Conversion orchestration (hev1 remux + 2-pass)
├── VideoExportSettings.swift               # Export settings
├── SmartFramingSettings.swift              # Smart framing settings
├── SmartFramingAnalyzer.swift              # Pass 1: Vision analysis + IOU tracking
├── VerticalVideoCompositor.swift           # Pass 2: Frame compositing + HDR tone mapping + watermark
├── CustomVideoCompositionInstruction.swift # AVVideoCompositionInstruction implementation
├── DockProgress.swift                      # Dock progress bar
├── VerticalConverter.entitlements          # Direct/Demo (sandbox disabled)
├── VerticalConverter_AppStore.entitlements  # AppStore (sandbox enabled)
└── PrivacyInfo.xcprivacy                   # Privacy Manifest (App Store requirement)
```

---

## Architecture

```
[Pre-processing]
  hev1 → hvc1 remux ──────┐
  DNxHD/DNxHR → error      │
  HDR metadata detection ──┘
                            ▼
[Pass 1] SmartFramingAnalyzer (when enabled)
  Person detection → IOU tracking → main subject estimation → interpolation → EMA → hold & follow
                            ▼
[Pass 2] VerticalVideoCompositor
  Tracking crop via precomputedOffsets / letterbox + blur background when OFF
  Tone mapping applied when HDR→SDR is ON
  Watermark composited for Demo edition
                            ▼
[Encoding]
  H.264/H.265 (SW) → VTCompressionSession
  H.264/H.265 (VT) → AVAssetWriter (HW)
  ProRes422 (VT)    → AVAssetWriter (HW)
  Audio              → AAC 192kbps
```

---

<details>
<summary><h2>📖 Smart Framing Details</h2></summary>

### ① FPS-dependent EMA (Exponential Moving Average)

```
α = 1 / (1 + fps × 0.2)
y[n] = α·x[n] + (1-α)·y[n-1]
```

| fps | α |
|:--|:--|
| 24 | ≈ 0.17 |
| 30 | ≈ 0.14 |
| 60 | ≈ 0.08 |

Causal smoothing via IIR filter (EMA). References only past frames, concentrating weight on the most recent frame while exponentially decaying older information. Bidirectional Gaussian references future frames and causes unnatural "pre-panning before the subject moves" behavior, so EMA is used instead. Consistent exponential decay model across the entire pipeline.

### ② IOU Tracking + Main Subject Estimation

```
Detection → PersonTracker (IOU matching) → subjectScore calculation → weighted center
```

**PersonTracker**
- Greedy matching with IOU ≥ 0.20
- Removed after 5 consecutive detection intervals (≈40 frames) without detection
- Each track accumulates `lifespan` (total detection count) and `velocities` (last 6 samples)

**subjectScore (subject likelihood)**

$$\text{score} = \text{confidence} \times \underbrace{\max(0.2,\ 1 - |x{-}0.5| \times 1.6)}_{\text{centrality}} \times \underbrace{\min\!\left(1,\ \frac{\text{lifespan}}{fps \times 1.5}\right)}_{\text{lifespanWeight}} \times \underbrace{\frac{1}{1 + v \times 6}}_{\text{motionWeight}}$$

| Case | Result |
|:--|:--|
| Group of 3 (equal) | All have long lifespan, low velocity → follows group center |
| Main subject + passerby | Passerby has short lifespan, high velocity → main subject dominates |

### ③ Adaptive Detection Interval

```swift
let deviation = hypot(center.x - lastCenter.x, center.y - lastCenter.y)
detectionInterval = deviation > 0.10 ? 4 : 8
```

Automatically shortens to every 4 frames during intense motion (dance, sports).

### ④ Y-axis Headroom Control

| Parameter | Value | Description |
|:--|:--|:--|
| yZoomFactor | 1.1 | 10% zoom-in to create Y-axis panning margin |
| targetRatio | 0.80 | Places upper body at 80% from the bottom |
| deadZoneRatio | 0.08 | Dead zone |
| minHoldFrames | fps × 0.5s | Y-axis hold duration |

### Stabilization Pipeline

- **detectAllPositions** — Detection at sampling intervals, hold between samples
- **Interpolation** — Short gaps: linear interpolation; long gaps: gradual return to fallback (center)
- **PersonTracker** — Maintains tracks within `maxMissed` range + hold center via `weightedCenterAllowingMissed()`
- **holdAndFollow** — Immediate snap at startup, warmup with `warmupFrames = 15` when following begins

</details>

<details>
<summary><h2>📖 HDR→SDR Conversion Details</h2></summary>

### Tone Mapping Modes

| Mode | macOS 15+ | macOS 14 Fallback |
|:--|:--|:--|
| **Natural** | CIToneMapHeadroom | Reinhard extended + highlight saturation suppression |
| **Cinematic** | CIToneMapHeadroom | ACES filmic curve |

### Processing Flow

1. Detect TransferFunction / ColorPrimaries / YCbCrMatrix from input track
2. Set color space properties on `AVMutableVideoComposition` (prevents implicit conversion)
3. Tag source pixel buffer with HLG/PQ color space → CIContext applies inverse OETF
4. Compress HDR values to [0, 1] via tone mapping
5. Render to SDR output in Rec.709

### HDR Passthrough

- Completely disable color management with `NSNull()` workingColorSpace on `CIContext`
- HEVC encoder input uses `32BGRA` (8-bit integer) to avoid double OETF
- H.264 / ProRes uses `64RGBAHalf` (16-bit float) to maximize HDR precision

### CIContext Warmup

Executes `composeFrame` twice on a dummy buffer via `renderContextChanged` to pre-initialize Metal shader compilation and texture caches. Prevents gamma/color shifts on Frame 0.

### AVMutableVideoComposition Color Space Properties

Sets `colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix` to match source HDR metadata. If unset, AVFoundation assumes BT.709 and applies implicit color space conversion, causing saturation shifts.

### HEVC HDR Passthrough Pixel Format Optimization

Apple's HEVC encoder interprets `64RGBAHalf` input as scene-linear and applies OETF. Since values from NSNull CIContext are already OETF-encoded, output uses `32BGRA` (integer) to avoid double application.

</details>

<details>
<summary><h2>📖 Implementation Notes</h2></summary>

### Encoding

- H.264 / H.265 (non-VT) → Software encoding via `VTCompressionSession`
- H.264 (VT) / H.265 (VT) → Hardware encoding via `AVAssetWriter`
- ProRes422 (VT) → Pre-checks HW encoder availability via `VTCopyVideoEncoderList`
- Uses HEVC Main10 profile for HDR passthrough
- HEVC SW encoder disables B-frames (`AllowFrameReordering = false`) for QTX/Finder compatibility

### Drag & Drop

- Fallback handling through NSURL / URL / Data / String ensures Finder drop compatibility
- Checkmark indicates "conversion complete"; freshly selected files show a neutral video icon

### Cancellation

- Safe resource cleanup via `CancelToken` + `VTSessionRegistry`
- Serializes `copyNextSampleBuffer()` on `videoReadQueue` (serial queue)
- `safeResume` guard prevents double continuation resume
- `VerticalVideoCompositor` tracks pending requests and calls `finishCancelledRequest()`

</details>

---

## Notes

- Smart Framing ON increases conversion time as all frames are scanned in Pass 1
- hev1 input is remuxed to hvc1 before conversion (no re-encoding)
- DNxHD/DNxHR cannot be decoded by macOS natively (requires Avid codec pack)
- Direct / Demo editions have App Sandbox disabled. On first launch, right-click → "Open", or run `xattr -cr VerticalConverter.app` to bypass Gatekeeper
- Demo edition outputs include a "DEMO" watermark after the free encode limit (5 per 24 hours)
- Demo usage can be reset via `defaults delete com.verticalconverter.app.demo DemoWindowStartDate && defaults delete com.verticalconverter.app.demo DemoEncodeCount`
- HDR features (HDR→SDR conversion, HDR passthrough) require macOS 14+. On macOS 13, the HDR panel is grayed out and HDR video input is rejected with an error message
- AppStore edition has App Sandbox enabled. Only user-selected files can be read/written

---

## Roadmap

- [x] Custom output resolution
- [x] Frame rate selection
- [x] Preview function
- [x] Smart framing (person tracking)
- [x] Batch processing (multiple file conversion)
- [x] HDR/HLG support (HDR→SDR conversion)
- [x] Strict bitrate control via AVAssetWriter
- [x] Software encoding via VTCompressionSession
- [x] Edition-based builds (Direct / Demo / AppStore)
- [x] Object detection (tracking non-person objects)
- [x] Explicit output path specification

---

## Changelog

### v1.0.1

- **Privacy Manifest** — Added `PrivacyInfo.xcprivacy` (required since May 2024). No tracking, no collected data types, no Required Reason APIs declared (app does not use UserDefaults or other Required Reason APIs)
- **App Store audit** — Verified the following are compliant:
  - App Sandbox (`com.apple.security.app-sandbox` + `files.user-selected.read-write`) in AppStore entitlements
  - hev1 remux temp files use `FileManager.temporaryDirectory` (sandbox-safe) with `defer` cleanup
  - VideoToolbox / ProRes hardware encoding works within sandbox without additional entitlements
  - Security-scoped resource access (`startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`) for both input files and output directory
- **Frame rate conversion fix** — Changed to `containsTweening = true` so `AVMutableVideoComposition.frameDuration` correctly controls output frame rate
- **Source FPS preserve mode** — Added "Src" option to FPS settings to preserve the source video's original frame rate
- **Output folder selection** — All editions (Direct/Demo/AppStore) can select output destination via `NSOpenPanel`. Reset button restores "Same as Input"
- **AppStore sandbox support** — Obtains write permissions via security-scoped folder selection
- **Crop label fix** — Fixed swapped display names for `centerPortrait4x3` / `centerPortrait3x4` (3:4 / 4:3)
- **Tooltips** — Added hover descriptions to Resolution / FPS / Codec / Container / Bitrate / Bitrate Mode / Crop / Follow Speed / Tone Map setting rows
- **GUI lock during encoding** — Drop zone, settings panel, smart framing, and HDR panels are `.disabled` during conversion (Cancel remains active)
- **Completion sound** — Plays macOS system sound (Glass) on single/batch conversion completion
- **About window** — Shows version, license (MIT + Commons Clause), and GitHub/X links from "About Vertical Converter" in the menu bar
- **Version display** — Shows app version below the "Convert 16:9 → 9:16" header
- **Progress bar UI improvement** — Reduced spacing between progress bar and status text for a more compact layout
- **Version updated to 1.0.1** — MARKETING_VERSION / CURRENT_PROJECT_VERSION updated across all 6 configurations
- **About window license display improvement** — Normalized paragraph line breaks in license text for natural word wrap. App Store edition shows MIT license body with a note that Commons Clause applies to source code. Direct/Demo edition loads the LICENSE file; falls back to full MIT + Commons Clause text on load failure.
- **Window width fixed at 560px, height only resizable**
Implemented with NSViewRepresentable + NSWindowDelegate(windowWillResize)
Used with .windowResizability(.automatic)
Confirmed to work on macOS 13+ (no API restrictions)
- **Last commit hash at time of MacAppStore submission**
a63e3d1841724ecdc9cc1316cd3c3926de540c06

---

## License

This project is licensed under the [MIT License + Commons Clause](LICENSE). See the LICENSE file for details.

<br>

<p align="center"><a href="#english">⬆ Back to top</a></p>

---

<h2 id="日本語">日本語</h2>

## スクリーンショット

<p align="center">
  <img src="VC_SS-1.jpg" alt="メイン画面" width="48%">&nbsp;&nbsp;
  <img src="VC_SS-2.jpg" alt="設定・変換画面" width="48%">
</p>

---

## 主な機能

### 🎬 変換 & クロップ

- **ドラッグ&ドロップ** — ファイルをウィンドウにドロップするだけ（複数ファイル対応）
- **バッチ変換** — 複数ファイルを一括選択し、順番に自動変換
- **5つのクロップモード** — Fit W / Fit H / Square / 4:3 / 3:4
- **クロッププレビュー** — サムネイル時刻シークつきでクロップ結果を事前確認

### 🧠 スマートフレーミング

- **Vision 人物追従** — 全フレームを解析し、被写体を自動追従しながら縦クロップ
- **IOU トラッキング** — 複数人物を個別追跡し、主役（長時間・安定）を自動推定
- **Y 方向ヘッドルーム** — ダンス・トーク動画でも頭の余白を自動確保
- **追従速度** — Fast / Normal / Slow の 3 段階から選択

### 🎨 HDR 対応

- **HDR → SDR 変換** — Natural / Cinematic トーンマッピング
- **HDR パススルー** — HLG/PQ/BT.2020 メタデータを保持したまま縦変換

### ⚙️ エンコード設定

| 設定 | 選択肢 |
|:--|:--|
| コーデック | H.264 / H.265 / H.264 (VT) / H.265 (VT) / ProRes422 (VT) |
| コンテナ | MOV / MP4（HEVC のみ選択可） |
| 解像度 | 720p (720×1280) / 1080p (1080×1920) |
| フレームレート | Src (ソース維持) / 24 / 29.97 DF / 30 / 60 fps |
| ビットレート | 8 / 10 / 12 Mbps |
| ビットレートモード | VBR / CBR / ABR |

### 🛡️ 入力の自動処理

- **hev1 → hvc1 自動リマックス**（再エンコードなし・品質劣化なし）
- **DNxHD/DNxHR 入力**を早期検知しエラーを返却
- **Dock プログレスバー**で変換進捗を表示

### 💻 UI / UX

- **出力フォルダ選択** — 全エディションで出力先を明示指定可能に。リセットボタンで「Same as Input」に戻せる
- **設定ツールチップ** — 各設定行にマウスホバーで英語の説明を表示
- **エンコード中 GUI ロック** — 変換中はドロップゾーン・設定パネル・スマートフレーミング・HDR パネルを `.disabled` でロック（Cancel は有効）
- **完了サウンド** — エンコード完了時に macOS システムサウンド (Glass) を再生
- **About ウィンドウ** — カスタムウィンドウバーなしの About 画面。アプリアイコン・紹介文・GitHub/X リンク・ライセンス全文を表示
- **バージョン表示** — ヘッダーの「Convert 16:9 → 9:16」の下にアプリバージョンを表示
- **プログレスバー UI 改善** — プログレスバーとステータステキスト間の余白を詰めてコンパクトに
- **バージョンを 1.0.1 に更新** — MARKETING_VERSION / CURRENT_PROJECT_VERSION を全 6 構成で更新
- **About ウィンドウ ライセンス表示改善** — ライセンステキストの段落内改行を正規化し、画面幅に合わせた自然な折り返しで表示。App Store 版は MIT ライセンス本文 + Commons Clause がソースコードのライセンスである旨の注記を表示。Direct / Demo 版は LICENSE ファイルを読み込み、読み込み失敗時は MIT + Commons Clause 全文をフォールバック表示

- **ウィンドウ横幅560px固定・高さのみリサイズ可能に変更**
NSViewRepresentable + NSWindowDelegate(windowWillResize)で実装
.windowResizability(.automatic)と併用
macOS 13+で動作確認済み（API制約なし）

---

## 技術仕様

| 項目 | 内容 |
|:--|:--|
| 対応 OS | macOS 13.0 以降（Apple Silicon 専用）。HDR 機能は macOS 14 以降が必要 |
| 言語 | Swift / SwiftUI |
| フレームワーク | AVFoundation, Vision, Core Image, VideoToolbox |
| 処理方式 | 2パス（解析 → 変換）。スマートフレーミング OFF 時は 1パス |
| 出力形式 | MP4（H.264 + AAC 192kbps）/ MOV・MP4（H.265 + AAC）/ MOV（ProRes422） |
| 出力解像度 | 720×1280 または 1080×1920（9:16） |

---

## ビルド

```bash
cd VerticalConverter
open VerticalConverter.xcodeproj
```

Xcode で Scheme を選択し、⌘+B（ビルド）または ⌘+R（実行）。

### エディション別 Build Configuration

ソースファイルは一本化。Build Configuration の `SWIFT_ACTIVE_COMPILATION_CONDITIONS` で `#if` 分岐します。

| Scheme | Debug / Release Config | フラグ | 特徴 |
|:--|:--|:--|:--|
| **VerticalConverter (Direct)** | Debug / Release | `EDITION_DIRECT` | 直販版。サンドボックス無効。MIT + Commons Clause |
| **VerticalConverter (Demo)** | Debug Demo / Release Demo | `EDITION_DEMO` | デモ版。24時間ごとに5回まではフル品質で出力、以降はウォーターマーク付き。UIに DEMO バッジ |
| **VerticalConverter (AppStore)** | Debug AppStore / Release AppStore | `EDITION_APPSTORE` | App Store 版。App Sandbox 有効 |

#### Entitlements

| エディション | ファイル | App Sandbox |
|:--|:--|:--|
| Direct / Demo | `VerticalConverter.entitlements` | 無効 |
| AppStore | `VerticalConverter_AppStore.entitlements` | **有効** + `files.user-selected.read-write` |

#### コマンドラインビルド

```bash
# 直販版
xcodebuild -scheme "VerticalConverter (Direct)" -configuration Release build

# デモ版
xcodebuild -scheme "VerticalConverter (Demo)" -configuration "Release Demo" build

# App Store 版
xcodebuild -scheme "VerticalConverter (AppStore)" -configuration "Release AppStore" build
```

---

## 使い方

1. 動画ファイルをウィンドウにドラッグ（複数可）、またはクリックして選択
2. 解像度・FPS・コーデック・ビットレート・クロップモードを設定
3. 必要に応じて **Preview** でクロップ結果を確認
4. 必要に応じて **スマートフレーミング** / **HDR→SDR 変換** を設定
5. **Start Conversion** をクリック
6. 完了後、Finder で保存先が自動表示

---

## プロジェクト構造

```
VerticalConverter/
├── VerticalConverterApp.swift              # エントリーポイント
├── BuildEdition.swift                      # エディション定義（#if で Direct/Demo/AppStore 分岐）
├── ContentView.swift                       # メインUI + ContentViewModel（バッチ対応）
├── VideoProcessor.swift                    # 変換オーケストレーション（hev1 リマックス + 2パス）
├── VideoExportSettings.swift               # エクスポート設定
├── SmartFramingSettings.swift              # スマートフレーミング設定
├── SmartFramingAnalyzer.swift              # 第1パス: Vision解析 + IOUトラッキング
├── VerticalVideoCompositor.swift           # 第2パス: フレーム合成 + HDRトーンマッピング + ウォーターマーク
├── CustomVideoCompositionInstruction.swift # AVVideoCompositionInstruction実装
├── DockProgress.swift                      # Dockプログレスバー
├── VerticalConverter.entitlements          # Direct/Demo 用（サンドボックス無効）
├── VerticalConverter_AppStore.entitlements  # AppStore 用（サンドボックス有効）
└── PrivacyInfo.xcprivacy                   # Privacy Manifest（App Store 必須）
```

---

## アーキテクチャ

```
[前処理]
  hev1 → hvc1 リマックス ─┐
  DNxHD/DNxHR → エラー    │
  HDR メタデータ検出 ──────┘
                           ▼
[第1パス] SmartFramingAnalyzer（ON時のみ）
  人物検出 → IOUトラッキング → 主役推定 → 座標補間 → EMA → ホールド&フォロー
                           ▼
[第2パス] VerticalVideoCompositor
  precomputedOffsets で追従クロップ ／ OFF時はレターボックス＋ブラー背景
  HDR→SDR ON 時はトーンマッピング適用
  Demo 版はウォーターマークを合成
                           ▼
[エンコード]
  H.264/H.265 (SW) → VTCompressionSession
  H.264/H.265 (VT) → AVAssetWriter (HW)
  ProRes422 (VT)    → AVAssetWriter (HW)
  オーディオ         → AAC 192kbps
```

---

<details>
<summary><h2>📖 スマートフレーミング詳細</h2></summary>

### ① fps 依存 EMA（指数移動平均）

```
α = 1 / (1 + fps × 0.2)
y[n] = α·x[n] + (1-α)·y[n-1]
```

| fps | α |
|:--|:--|
| 24 | ≈ 0.17 |
| 30 | ≈ 0.14 |
| 60 | ≈ 0.08 |

IIR フィルタ（EMA）による因果的スムージング。過去のみを参照し、直近フレームに重みを集中させ、古い情報は指数的に減衰。双方向ガウシアンは未来フレームを参照し「被写体が動く前にカメラが先読みでパンする」不自然な挙動を生むため、EMA で置換。パイプライン全体で一貫した指数減衰モデル。

### ② IOU トラッキング + 主役推定

```
検出 → PersonTracker（IOUマッチング）→ subjectScore 計算 → 加重中心
```

**PersonTracker**
- IOU ≥ 0.20 でグリーディマッチング
- 連続 5 検出間隔（≈40 フレーム）未検出で削除
- 各トラックに `lifespan`（累計検出回数）・`velocities`（直近 6 サンプル）を蓄積

**subjectScore（主役らしさ）**

$$\text{score} = \text{confidence} \times \underbrace{\max(0.2,\ 1 - |x{-}0.5| \times 1.6)}_{\text{centrality}} \times \underbrace{\min\!\left(1,\ \frac{\text{lifespan}}{fps \times 1.5}\right)}_{\text{lifespanWeight}} \times \underbrace{\frac{1}{1 + v \times 6}}_{\text{motionWeight}}$$

| ケース | 結果 |
|:--|:--|
| グループ 3 人（等価） | 全員が長寿命・低速度 → グループ中心を追う |
| 主役＋通過者 | 通過者は短命・高速 → 主役が支配的 |

### ③ 適応的検出間隔

```swift
let deviation = hypot(center.x - lastCenter.x, center.y - lastCenter.y)
detectionInterval = deviation > 0.10 ? 4 : 8
```

激しい動き（ダンス・スポーツ）では 4 フレーム毎に自動短縮。

### ④ Y 方向ヘッドルーム制御

| パラメータ | 値 | 説明 |
|:--|:--|:--|
| yZoomFactor | 1.1 | 10% ズームインで Y 方向パン余白を確保 |
| targetRatio | 0.80 | 下から 80% の位置に上半身を配置 |
| deadZoneRatio | 0.08 | 不感帯 |
| minHoldFrames | fps × 0.5s | Y 方向ホールド時間 |

### 安定化パイプライン

- **detectAllPositions** — サンプリング間隔で検出、サンプル間はホールド
- **補間** — 短いギャップは線形補間、長いギャップは fallback（中央）へ徐々に復帰
- **PersonTracker** — `maxMissed` 範囲内のトラック維持 + `weightedCenterAllowingMissed()` によるホールド中心
- **holdAndFollow** — 起動直後は即時スナップ、フォロー開始時は `warmupFrames = 15` でウォームアップ

</details>

<details>
<summary><h2>📖 HDR→SDR 変換詳細</h2></summary>

### トーンマッピングモード

| モード | macOS 15+ | macOS 14 フォールバック |
|:--|:--|:--|
| **Natural** | CIToneMapHeadroom | Reinhard extended + ハイライト彩度抑制 |
| **Cinematic** | CIToneMapHeadroom | ACES filmic カーブ |

### 処理フロー

1. 入力トラックから TransferFunction / ColorPrimaries / YCbCrMatrix を検出
2. `AVMutableVideoComposition` に色空間プロパティを設定（暗黙変換を防止）
3. ソースピクセルバッファを HLG/PQ カラースペースでタグ付け → CIContext が逆 OETF を適用
4. トーンマッピングで HDR 値を [0, 1] に圧縮
5. Rec.709 で SDR 出力にレンダリング

### HDR パススルー

- `CIContext` に `NSNull()` workingColorSpace で色管理を完全無効化
- HEVC エンコーダ入力は `32BGRA`（8bit 整数）で二重 OETF を回避
- H.264 / ProRes は `64RGBAHalf`（16bit float）で HDR 精度を最大化

### CIContext ウォームアップ

`renderContextChanged` で dummy バッファに対し `composeFrame` を 2 回実行し、Metal シェーダーコンパイル・テクスチャキャッシュを事前初期化。Frame 0 でのガンマ/色ずれを防止。

### AVMutableVideoComposition の色空間プロパティ

`colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix` をソース HDR メタデータに合わせて設定。未設定の場合、AVFoundation が BT.709 を想定し暗黙の色空間変換を適用するため、彩度が変化する。

### HEVC HDR パススルーのピクセルフォーマット最適化

Apple の HEVC エンコーダは `64RGBAHalf` 入力を scene-linear と解釈し OETF を適用する。NSNull CIContext からの値は既に OETF エンコード済みのため、二重適用を回避するために `32BGRA`（整数）で出力。

</details>

<details>
<summary><h2>📖 実装メモ</h2></summary>

### エンコード

- H.264 / H.265（非 VT）→ `VTCompressionSession` によるソフトウェアエンコード
- H.264 (VT) / H.265 (VT) → `AVAssetWriter` によるハードウェアエンコード
- ProRes422 (VT) → `VTCopyVideoEncoderList` で HW エンコーダの有無を事前チェック
- HDR パススルー時は HEVC Main10 プロファイル
- HEVC SW エンコーダは B フレーム無効化（`AllowFrameReordering = false`）で QTX/Finder 互換を確保

### ドラッグ&ドロップ

- NSURL / URL / Data / String を順に扱うフォールバック処理で Finder ドロップ互換性を確保
- チェックマークは「変換完了」、ファイル選択直後は中立的なビデオアイコンを表示

### キャンセル処理

- `CancelToken` + `VTSessionRegistry` による安全なリソース解放
- `videoReadQueue`（直列キュー）で `copyNextSampleBuffer()` を直列化
- `safeResume` ガードで継続の二重 resume を防止
- `VerticalVideoCompositor` で保留中リクエストを追跡し `finishCancelledRequest()` を呼出

</details>

---

## 注意事項

- スマートフレーミング ON 時は第 1 パスで全フレームをスキャンするため変換時間が増加
- hev1 入力は変換前に hvc1 へリマックス（再エンコードなし）
- DNxHD/DNxHR は macOS 標準ではデコード不可（Avid コーデックパックが必要）
- Direct / Demo 版は App Sandbox 無効。初回起動時は右クリック →「開く」、または `xattr -cr VerticalConverter.app` で Gatekeeper を解除
- Demo 版は 24 時間ごとに 5 回のフリーエンコード後、出力動画に「DEMO」ウォーターマークが入ります
- Demo 版の使用回数は `defaults delete com.verticalconverter.app.demo DemoWindowStartDate && defaults delete com.verticalconverter.app.demo DemoEncodeCount` でリセット可能
- HDR 機能（HDR→SDR 変換、HDR パススルー）は macOS 14 以降が必要。macOS 13 では HDR パネルがグレーアウトされ、HDR 動画入力時にはエラーメッセージが表示されます
- AppStore 版は App Sandbox 有効。ユーザーが選択したファイルのみ読み書き可能

---

## ロードマップ

- [x] カスタム出力解像度
- [x] フレームレート選択
- [x] プレビュー機能
- [x] スマートフレーミング（人物追従）
- [x] バッチ処理（複数ファイル一括変換）
- [x] HDR/HLG 対応（HDR→SDR 変換）
- [x] AVAssetWriter による厳密なビットレート制御
- [x] VTCompressionSession によるソフトウェアエンコード
- [x] エディション別ビルド（Direct / Demo / AppStore）
- [x] 物体検出（人物以外のオブジェクト追従）
- [x] 保存先・ファイル名の明示指定

---

## 更新履歴

### v1.0.1

- **Privacy Manifest** — Added `PrivacyInfo.xcprivacy` (required since May 2024). No tracking, no collected data types, no Required Reason APIs declared (app does not use UserDefaults or other Required Reason APIs)
- **App Store audit** — Verified the following are compliant:
  - App Sandbox (`com.apple.security.app-sandbox` + `files.user-selected.read-write`) in AppStore entitlements
  - hev1 リマックス一時ファイルは `FileManager.temporaryDirectory`（サンドボックス安全）を使用し `defer` でクリーンアップ
  - VideoToolbox / ProRes ハードウェアエンコードはサンドボックス内で追加 entitlement なしに動作
  - セキュリティスコープ付きリソースアクセス（入力ファイル・出力ディレクトリの両方で `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource` を使用）
- **フレームレート変換修正** — `containsTweening = true` に変更し、`AVMutableVideoComposition.frameDuration` によるフレームレート変換が正しく動作するように
- **ソースFPS維持モード追加** — FPS設定に「Src」オプションを追加。ソース動画のフレームレートをそのまま維持可能
- **出力フォルダ選択** — 全エディション（Direct/Demo/AppStore）で出力先フォルダを `NSOpenPanel` で選択可能に。リセットボタンで「Same as Input」に戻せる
- **AppStore サンドボックス対応** — セキュリティスコープ付きフォルダ選択で書き込み権限を取得
- **Crop ラベル修正** — `centerPortrait4x3` / `centerPortrait3x4` の表示名が逆になっていたのを修正（3:4 / 4:3）
- **ツールチップ追加** — Resolution / FPS / Codec / Container / Bitrate / Bitrate Mode / Crop / Follow Speed / Tone Map の各設定行にホバーで説明を表示
- **エンコード中 GUI ロック** — 変換中はドロップゾーン・設定パネル・スマートフレーミング・HDR パネルを `.disabled` でロック（Cancel は有効）
- **完了サウンド** — 単体・バッチ変換完了時に macOS システムサウンド (Glass) を再生
- **About ウィンドウ** — メニューバーの「About Vertical Converter」でバージョン・ライセンス (MIT + Commons Clause)・GitHub/X リンクを表示
- **バージョン表示** — ヘッダーの「Convert 16:9 → 9:16」の下にアプリバージョンを表示
- **プログレスバー UI 改善** — プログレスバーとステータステキスト間の余白を詰めてコンパクトに
- **バージョンを 1.0.1 に更新** — MARKETING_VERSION / CURRENT_PROJECT_VERSION を全 6 構成で更新
- **About ウィンドウ ライセンス表示改善** — ライセンステキストの段落内改行を正規化し、画面幅に合わせた自然な折り返しで表示。App Store 版は MIT ライセンス本文 + Commons Clause がソースコードのライセンスである旨の注記を表示。Direct / Demo 版は LICENSE ファイルを読み込み、読み込み失敗時は MIT + Commons Clause 全文をフォールバック表示

- **ウィンドウ横幅560px固定・高さのみリサイズ可能に変更**
NSViewRepresentable + NSWindowDelegate(windowWillResize)で実装
.windowResizability(.automatic)と併用
macOS 13+で動作確認済み（API制約なし）

- **MacAppStore提出時の最終コミットハッシュ**
a63e3d1841724ecdc9cc1316cd3c3926de540c06


---

## ライセンス

**MIT + Commons Clause** — 詳細は [LICENSE](LICENSE) をご覧ください。

<br>

<p align="center"><a href="#english">⬆ Back to top</a></p>
