# VerticalConverter HDR 修正・改修メモ

**日付**: 2026-03-06 〜 2026-03-09

---

## セッション経緯

### Phase 1: バグ報告・コードベース解析（03-06）

HDR 素材を扱う際に以下 3 つのバグが報告された。全ソースファイル（`VideoProcessor.swift`, `VerticalVideoCompositor.swift`, `VideoExportSettings.swift`, `CustomVideoCompositionInstruction.swift`, `ContentView.swift`）を通読し、根本原因を特定した。

### Phase 2: 第 1 次修正（失敗）（03-06）

- `CIContext` の `workingColorSpace` を `extendedLinearSRGB` → **`extendedLinearITUR_2020`** に変更
- HEVC コンテナを `.mp4` → `.mov` に変更
- `staticInputSize` 導入、VTB フラッシュに `CMTime.invalid` 使用

**結果**: ユーザーから「HDR パススルーの色は改善せず、H.265 (SW) はむしろ悪化」と報告。スクリーンショットではブラー背景がシアン（上部）とオレンジ（下部）に完全に壊れていた。`extendedLinearITUR_2020` は Metal パイプライン内部でフィルタ処理中に想定外の色空間変換を引き起こしていた。

### Phase 3: 第 2 次修正（03-06）

- `extendedLinearITUR_2020` を撤回し、HDR パススルー時は **`NSNull()`**（カラーマネジメント完全無効化）に変更
- `composeFrame()` のソース画像生成・レンダリングも `colorSpace` なしに統一
- `.mov` コンテナ変更、`staticInputSize`、VTB フラッシュ改善は第 1 次から維持

### Phase 4: libplacebo フィジビリティ調査（03-06）

自前 HDR→SDR トーンマッピングの品質問題が根本にあるため、libplacebo への置換を検討。GitHub README、`tone_mapping.h`、`shaders/colorspace.h`、CI 設定、Homebrew formula を調査し、「技術的には可能だが統合コスト・ライセンス制約から非推奨」と結論。

### Phase 5: 今後の方針決定（03-06）

libplacebo を見送り、現実的な選択肢として (1) `CIToneMapHeadroom` 一本化、(2) Metal Compute Shader 自前実装 を今後の候補とした。

### Phase 6: CIToneMapHeadroom 実装 + 彩度問題の発見と解決（03-07）

- `applyToneMapping()` で Natural / Cinematic **両方**に `CIToneMapHeadroom`（macOS 15+）を適用。macOS 14 以下は Reinhard / ACES カーネルにフォールバック。
- テストで **HDR パススルー・HDR→SDR 両方で彩度が上がる**問題を発見。
- 原因: `AVMutableVideoComposition` に `colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix` が未設定だったため、AVFoundation がデフォルト BT.709 を想定し、BT.2020 ソースに対して暗黙の色空間変換を適用していた。
- 修正: **全 HDR 入力**（パススルー・HDR→SDR 問わず）に対してソースの HDR プロパティを `videoComposition` に設定。AVFoundation が未変換の BT.2020/HLG/PQ フレームをコンポジターに渡すようにした。

### Phase 7: H.265 SW B フレーム問題（03-07）

- H.265 SW エンコーダの出力が QuickTime Player / Finder で再生不可になる場合があった。
- 原因: Software HEVC エンコーダの B フレーム並べ替えが macOS の再生エンジンと不整合。
- 修正: `kVTCompressionPropertyKey_AllowFrameReordering = false` を設定。

### Phase 8: HEVC HDR パススルーの SDR トーン問題 — 原因特定（03-08）

- テストで H.264 の HDR パススルーは正常だが、**H.265（SW/HW 両方）の HDR パススルーが暗い SDR トーン**に見える問題を発見。
- スクリーンショット比較で明確に確認: H.264 `.mp4` は明るい HDR、H.265 `.mov` は暗いフラットな SDR 調。
- 最初の試みとして per-frame `TransferFunction` スタンプを除去したが改善せず（セッションレベルの TF プロパティが OETF 適用を駆動するため）。

**根本原因の特定**:
Apple の HEVC エンコーダ（SW/HW 両方）は `64RGBAHalf`（float）入力を「シーンリニア（scene-referred）」データとして解釈する。セッションレベルの TransferFunction が HLG/PQ の場合、エンコーダはフロート値に OETF 曲線を適用してから量子化する。しかし NSNull CIContext からの値は**既に OETF エンコード済み**のため、二重適用（double-OETF）が起こり、ダイナミックレンジが圧縮されて SDR のような暗い出力になる。H.264 と ProRes には HDR 対応エンコードパイプラインがないため、フロート値をそのまま量子化し、問題が発生しない。

### Phase 9: 二重 OETF 修正 — 整数フォーマット化（03-09）

- HEVC HDR パススルー時のコンポジター出力を `64RGBAHalf`（float）→ **`32BGRA`（8bit 整数）** に変更。
- HEVC エンコーダは整数データを「ディスプレイリファード（display-referred）」として扱い、OETF を適用しない。
- per-frame TransferFunction スタンプを復活（整数フォーマットでは二重 OETF にならないため安全）。
- H.264 / ProRes の HDR パススルーは従来通り `64RGBAHalf` を維持（これらのエンコーダは HDR パイプラインを持たない）。
- テスト結果: **全 12 コーデック×変換パスの組み合わせで正常動作を確認**。

### Phase 10: コンテナフォーマット選択機能（03-09）

- HEVC の出力コンテナを `.mov`（デフォルト）/ `.mp4` で選択可能にする UI を追加。
- H.264 は常に `.mp4`、ProRes は常に `.mov`（変更不可）。
- `VideoExportSettings.ContainerFormat` enum と `resolvedFileExtension` 計算プロパティを追加。

---

## 報告されたバグ

HDR 素材を扱う際に以下のバグが報告された。

| # | 症状 | 原因 | 解決 Phase |
|---|------|------|-----------|
| 1 | HDR パススルー（変換なし）で色が変わる | `CIContext` の `workingColorSpace` が `extendedLinearSRGB` のため BT.2020→sRGB→BT.2020 のガマット往復が発生し、特にブラー背景で色相が大きくシフトする | Phase 3 |
| 2 | H.265 (SW) 書き出しが QuickLook / QTX で再生不可 | Software HEVC エンコーダの出力を `.mp4` コンテナに入れていたため、macOS の QuickLook/QTX が Main10 HDR メタデータを正しく解釈できなかった | Phase 2 |
| 3 | H.264 (SW) 以外の書き出しでフレーム 0 のガンマが狂う | `CIContext` / Metal の内部状態（シェーダーコンパイル・テクスチャキャッシュ・IOSurface バッキング）がフレーム 0 到着時に lazy init され、本番フレームとは異なる Metal パスが走る | Phase 2-3 |
| 4 | HDR パススルー・HDR→SDR 両方で彩度が上がる | `AVMutableVideoComposition` に色空間プロパティが未設定 → AVFoundation がデフォルト BT.709 を想定し、BT.2020 ソースに暗黙の色空間変換を適用 | Phase 6 |
| 5 | H.265 SW の B フレームで QTX 再生不可 | Software HEVC エンコーダの B フレーム並べ替えが macOS 再生エンジンと不整合 | Phase 7 |
| 6 | H.265 (SW/HW) HDR パススルーが暗い SDR トーン | HEVC エンコーダが `64RGBAHalf` を scene-linear と解釈し、既に OETF エンコード済み値に二重 OETF を適用 | Phase 9 |

---

## 実施した修正

### 1. HDR パススルー時の色保持 — `CIContext` カラーマネジメント無効化

**対象**: `VerticalVideoCompositor.swift` — `init()`

```swift
// 変更前
let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
ciContext = CIContext(options: [.workingColorSpace: workingCS])

// 変更後（HDR パススルー時のみ）
if isHDRPassthrough {
    ciContext = CIContext(options: [.workingColorSpace: NSNull()])
} else {
    let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    ciContext = CIContext(options: [.workingColorSpace: workingCS])
}
```

**意図**: `NSNull()` を指定することで CIContext のカラーマネジメントを完全に無効化。OETF エンコード済みの HLG/PQ 値が幾何変換・ガウシアンブラーをそのまま通り、エンコーダへ直送される。カラースペース変換の往復誤差がゼロになる。

> **注意**: `extendedLinearITUR_2020` への変更も試みたが、Metal パイプラインでシアン/オレンジのアーティファクトが発生し採用不可だった。

---

### 2. HEVC コンテナを `.mov` に変更

**対象**: `VideoProcessor.swift` — `exportVideo()` 内の AVAssetWriter セットアップ、`ContentView.swift` — 出力拡張子

```swift
// VideoProcessor.swift
switch codec {
case .prores422VT, .h265, .h265VT:
    fileType = .mov
default:
    fileType = .mp4
}

// ContentView.swift
switch capturedExportSettings.codec {
case .prores422VT, .h265, .h265VT:
    outExt = "mov"
default:
    outExt = "mp4"
}
```

**意図**: `.mov` は Apple ネイティブコンテナであり、HEVC Main10 / HDR メタデータの格納に `.mp4` より信頼性が高い。macOS の QuickLook / QuickTime X が SW HEVC を正しく再生できるようになる。

---

### 3. フレーム 0 ガンマ狂い対策 — `primeCIContext()` 改善

**対象**: `VerticalVideoCompositor.swift` — `primeCIContext()`、`VideoProcessor.swift`

#### 3-a. `staticInputSize` の導入

```swift
// VerticalVideoCompositor.swift
static var staticInputSize: CGSize = .zero

// VideoProcessor.swift（compositor 起動前に設定）
VerticalVideoCompositor.staticInputSize = inputSize
```

`primeCIContext()` のウォームアップで **入力動画と同サイズ** のソースバッファを使用するように変更。以前は出力サイズ (`renderSize`) を流用しており、CIContext / Metal が異なるテクスチャアロケーションパスを選択する原因となっていた。

#### 3-b. VTCompressionSession フラッシュに `CMTime.invalid` を使用

```swift
// 変更前
VTCompressionSessionCompleteFrames(compSession, untilPresentationTimeStamp: warmupPTS)

// 変更後
VTCompressionSessionCompleteFrames(compSession, untilPresentationTimeStamp: CMTime.invalid)
```

**意図**: `CMTime.invalid` は「保留中の全フレームを強制フラッシュ」を意味する。HEVC エンコーダは B フレーム並べ替えを行うため、特定 PTS を指定するとウォームアップフレームが残留しうる。`.invalid` で確実に排出する。

#### 3-c. IOSurface + 非ゼロデータでの本番パス通し

`primeCIContext()` では以下の手順で本番と同一の Metal パスを事前に走らせる:

1. IOSurface + Metal 互換属性付きの `CVPixelBuffer` を生成
2. 非ゼロ値（HDR: half-float 2.0 = `0x4000`、SDR: mid-gray `0x80`）を書き込み（Metal fast-clear 最適化を回避）
3. 本番 `composeFrame()` を **2 回**実行（1 回目: シェーダーコンパイル + パイプラインステート生成、2 回目: コマンドバッファの定常状態確立）

---

### 4. `composeFrame()` の HDR パススルー時レンダリング変更

**対象**: `VerticalVideoCompositor.swift` — `composeFrame()`

- ソース画像生成: `CIImage(cvPixelBuffer:)` — `colorSpace` オプション未指定（NSNull CIContext に合わせカラースペースタグを付けない）
- レンダリング: `ciContext.render(_, to:, bounds:, colorSpace: nil)` — 出力カラースペースも nil で完全パススルー

---

## libplacebo 検討結果

自前 HDR→SDR トーンマッピング（Reinhard / ACES CIColorKernel）を libplacebo に置き換える案について調査した。

### 結論: **技術的には可能だが、コスト高。現時点では非推奨。**

| 項目 | 詳細 |
|------|------|
| ライセンス | LGPL-2.1（動的リンク必須、App Store 配布に制約あり） |
| GPU API | Vulkan 1.2 / OpenGL 3.0 / D3D11 — macOS は MoltenVK 経由 |
| CPU のみ | Tier 0: 1D トーンマップ LUT 生成のみ。ガマットマッピング・3D LUT は GPU 必須 |
| ビルド | meson + pkg-config。Swift から呼ぶには C bridging header + Vulkan/MoltenVK リンクが必要 |
| 統合コスト | AVFoundation ↔ Vulkan 間のピクセルバッファ受け渡し実装が必要。Metal テクスチャ → VkImage 変換は MoltenVK 経由 |
| 依存肥大 | vulkan-loader, MoltenVK, shaderc, lcms2 等が必要 |

---

## Phase 6-9 で追加・変更した修正

### 5. CIToneMapHeadroom 一本化（Phase 6）

**対象**: `VerticalVideoCompositor.swift` — `applyToneMapping()`

macOS 15+ では Natural / Cinematic 両方に `CIToneMapHeadroom` を適用。macOS 14以下は Reinhard（Natural）/ ACES（Cinematic）にフォールバック。

```swift
// macOS 15+
if #available(macOS 15.0, *) {
    let toneMap = CIFilter(name: "CIToneMapHeadroom")!
    toneMap.setValue(image, forKey: kCIInputImageKey)
    toneMap.setValue(sourceHeadroom, forKey: "inputSourceHeadroom")  // HLG: 4.0, PQ: 16.0
    toneMap.setValue(1.0, forKey: "inputTargetHeadroom")             // SDR
    return toneMap.outputImage!
}
```

### 6. AVMutableVideoComposition の色空間プロパティ設定（Phase 6）

**対象**: `VideoProcessor.swift` — `createComposition()`

**原因**: `videoComposition` に `colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix` を設定しない場合、AVFoundation はデフォルト BT.709 を想定し、BT.2020 HDR フレームに暗黙の色空間変換を適用してコンポジターに渡す。これが全パス（パススルー・HDR→SDR）で彩度増加を引き起こしていた。

```swift
// 全 HDR 入力に対してソースの HDR プロパティを設定
if isHDR {
    videoComposition.colorPrimaries = detPrimaries         // e.g. ITU_R_2020
    videoComposition.colorTransferFunction = detTransfer    // e.g. ITU_R_2100_HLG
    videoComposition.colorYCbCrMatrix = detMatrix           // e.g. ITU_R_2020
}
```

**重要**: HDR→SDR 変換時も BT.709 ではなくソース HDR プロパティを設定する。BT.709 にすると AVFoundation が BT.2020→BT.709 変換を**コンポジター到達前に**適用し、トーンマッパーとの二重変換になる。

### 7. H.265 SW B フレーム無効化（Phase 7）

**対象**: `VideoProcessor.swift` — VTCompressionSession 設定

```swift
VTSessionSetProperty(compSession,
    key: kVTCompressionPropertyKey_AllowFrameReordering,
    value: kCFBooleanFalse)
```

### 8. HEVC HDR パススルーの二重 OETF 修正（Phase 8-9）

**根本原因の技術的詳細**:

```
[NSNull CIContext]                    [HEVC Encoder]
   ↓                                      ↓
HLG/PQ OETF済み値 → 64RGBAHalf → HEVC が「scene-linear」と判断
                                   → セッション TF=HLG の場合 OETF を適用
                                   → 二重 OETF → 圧縮されたダイナミックレンジ
                                   → SDR のような暗い出力
```

H.264 / ProRes は HDR 対応エンコードパイプラインを持たないため、float 値をそのまま量子化し問題なし。HEVC のみが float 入力を scene-referred と解釈する。

**修正**: HEVC HDR パススルー時のコンポジター出力を **`kCVPixelFormatType_32BGRA`（8bit 整数）** に変更。整数データに対して HEVC エンコーダは display-referred として扱い、OETF を適用しない。

**変更箇所**:

| ファイル | 変更内容 |
|---------|---------|
| `VerticalVideoCompositor.swift` | `static var staticIsHEVCOutput: Bool` を追加 |
| `VerticalVideoCompositor.swift` | `requiredPixelBufferAttributesForRenderContext`: HEVC+HDR パススルー → 32BGRA |
| `VerticalVideoCompositor.swift` | `primeCIContext()`: 出力フォーマットを同上に合わせる |
| `VerticalVideoCompositor.swift` | `composeFrame()`: per-frame TransferFunction スタンプを復活（整数では安全） |
| `VideoProcessor.swift` | `createComposition()` に `codec` パラメータ追加、`staticIsHEVCOutput` 設定 |
| `VideoProcessor.swift` | `preferredPixelFormat`: HEVC+HDR パススルー → 32BGRA |
| `VideoProcessor.swift` | VTB エンコードループ: per-frame TF スタンプ復活 |

**ピクセルフォーマット決定マトリクス**:

| 条件 | コンポジター出力 | AVAssetReader |
|------|-----------------|---------------|
| HDR パススルー + H.264/H.264VT | 64RGBAHalf | 64RGBAHalf |
| HDR パススルー + **H.265/H.265VT** | **32BGRA** | **32BGRA** |
| HDR パススルー + ProRes | 32BGRA | 32BGRA |
| HDR→SDR（全コーデック） | 32BGRA | 32BGRA |
| SDR（全コーデック） | 32BGRA | 32BGRA |

**10bit 整数の検討**: `kCVPixelFormatType_ARGB2101010LEPacked` への変更も検討したが、以下の理由で見送り:
- CIContext の render 先として未保証（黒フレームやクラッシュの可能性）
- VTCompressionSession がネイティブ入力として受け付けるか未確認
- HLG/PQ の OETF 曲線は暗部に bit を多く割り当てるため、8bit でもバンディングが目立ちにくい
- 将来バンディングが報告された場合は `kCVPixelFormatType_64ARGB`（16bit 整数）が安全な代替

### 9. コンテナフォーマット選択（Phase 10）

**対象**: `VideoExportSettings.swift`, `VideoProcessor.swift`, `ContentView.swift`

HEVC の出力コンテナを `.mov`（デフォルト）/ `.mp4` で選択可能にする UI を追加。

```swift
enum ContainerFormat: String, CaseIterable, Hashable {
    case mov = "MOV"
    case mp4 = "MP4"
}
```

| コーデック | Container設定 | 出力 |
|-----------|-------------|------|
| H.264 / H.264 VT | （無視） | `.mp4` 固定 |
| H.265 / H.265 VT + MOV | MOV | `.mov`（デフォルト） |
| H.265 / H.265 VT + MP4 | MP4 | `.mp4` |
| ProRes422 VT | （無視） | `.mov` 固定 |

---

## 最終テスト結果（2026-03-09）

全 12 コーデック×変換パスの組み合わせで正常動作を確認。

| コーデック | HDR パススルー | HDR→SDR |
|-----------|-------------|---------|
| H.264 (SW) | ✅ OK | ✅ OK |
| H.265 (SW) | ✅ OK | ✅ OK |
| H.264 (VT) | ✅ OK | ✅ OK |
| H.265 (VT) | ✅ OK | ✅ OK |
| ProRes422 (VT) | ✅ OK | ✅ OK |

---

## 今後の予定

### 選択肢 1（実装済み）: `CIToneMapHeadroom` 一本化 ✅

macOS 15+ で Natural / Cinematic 両方に `CIToneMapHeadroom` を適用。macOS 14 以下は Reinhard / ACES フォールバック。

### 選択肢 2: Metal Compute Shader で BT.2390 / スプライン曲線を自前実装

libplacebo のトーンマッピングアルゴリズム（BT.2390 EETF / Hable / mobius 等）を MSL (Metal Shading Language) に移植する案。

- **実装内容**:
  - Metal compute shader (.metal ファイル) で BT.2390 EETF カーブ + ICtCp 色空間でのガマットマッピングを実装
  - `CIFilter` ラッパーを作成し、既存の `applyToneMapping()` から呼び出し
  - トーンマッピングパラメータ（ピーク輝度、ニー開始点等）をシェーダー uniform で公開
- **メリット**:
  - 外部依存ゼロ（Metal は macOS 標準）
  - Apple GPU に最適化されたパフォーマンス
  - CIContext / CIImage パイプラインにシームレスに統合可能
  - BT.2390 は放送業界標準であり、品質が保証される
  - macOS 14 以下でも動作可能
- **デメリット**:
  - MSL での ICtCp 変換 + EETF 実装にある程度の工数
  - テストに HDR ディスプレイ環境が必要
- **工数**: 中（Metal shader 実装 + CIFilter ラッパー + テスト）

### 優先度

**選択肢 1 → 選択肢 2** の順で進めるのが妥当。選択肢 1 は最小コストで Apple 標準品質が得られるため先にフィードバックを取り、それで品質が不十分な場合に選択肢 2 で自前実装する。

---
---

# v1.0.1 機能追加・バグ修正メモ

**日付**: 2026-03-12 〜 2026-03-13

---

## セッション経緯

### Phase 11: AppStore サンドボックス書き込みエラー修正（03-12）

AppStore Scheme でエンコード実行時、`AVAssetWriter` が `startWriting()` で status=3（failed）、エラー「The file couldn't be saved because you don't have permission.」を返す問題。

**原因**: App Sandbox 有効時、ソース動画と同じディレクトリに書き込む処理がセキュリティスコープ外で失敗。`NSOpenPanel` の `canChooseFiles` で選択したファイルの **親ディレクトリ** にしかアクセス権がなく、任意の出力を作成できなかった。

**修正**:
- `NSOpenPanel` で `canChooseDirectories = true` の出力フォルダ選択ダイアログを追加
- `ContentViewModel` に `outputDirectoryURL: URL?` と `selectOutputDirectory()` メソッドを追加
- settingsPanel に全エディション共通の出力フォルダ行（リセット × ボタン付き）を追加

### Phase 12: 6 つの UI 改善（03-12）

1. **出力フォルダリセットボタン** — × ボタンで `outputDirectoryURL = nil`（入力と同じディレクトリに戻す）
2. **About ウィンドウ** — `CommandGroup(replacing: .appInfo)` で HTML credits 付きの About パネルを表示
3. **バージョン表示** — `CFBundleShortVersionString` でヘッダーにバージョン番号表示
4. **v1.0.1 更新** — `project.pbxproj` 全 6 構成の `MARKETING_VERSION = 1.0.1` / `CURRENT_PROJECT_VERSION = 2`
5. **エンコード中 GUI ロック** — `.disabled(viewModel.isProcessing)` で dropZone / settingsPanel / smartFramingPanel / hdrPanel を無効化
6. **完了サウンド** — `NSSound(named: .init("Glass"))?.play()` を単体・バッチ変換完了時に再生

### Phase 13: FPS Src モード + Crop ラベル修正 + ツールチップ（03-12〜13）

- FPS に「ソース維持」モードを追加
- Crop の 4:3/3:4 ラベルが逆だった問題を修正
- 全設定行にツールチップを追加

### Phase 14: フレームレート変換が実際に適用されない問題（03-13）

- `containsTweening = false` → `true` に変更しフレームレート変換を有効化
- `AVVideoExpectedSourceFrameRateKey` / `kVTCompressionPropertyKey_ExpectedFrameRate` を動的化

### Phase 15: UI 微調整・ドキュメント（03-13）

- プログレスバーとステータステキスト間のスペーシング縮小
- About ウィンドウにライセンス情報追加
- README に English / 日本語 切り替えナビゲーション追加


---

## 技術的詳細

### 10. FPS「Src」ソース維持モード（Phase 13）

**対象**: `VideoExportSettings.swift`, `VideoProcessor.swift`

`FrameRate` enum に `.source` ケースを追加。ソース動画本来のフレームレートを維持する。

```swift
// VideoExportSettings.swift
enum FrameRate: Hashable, CaseIterable {
    case source      // ← 追加
    case fps24
    case fps2997
    case fps30
    case fps60

    var frameDuration: CMTime {
        switch self {
        case .source: return .invalid   // sentinel 値
        // ...
        }
    }
}
```

**VideoProcessor.swift での解決ロジック**:

`exportVideo()` 内で `.source` の場合に `videoTrack.load(.nominalFrameRate)` を非同期ロードし、実際の frameDuration を算出:

```swift
let resolvedFrameDuration: CMTime
if settings.frameRate == .source {
    let nominalFPS = try await videoTrack.load(.nominalFrameRate)
    let fps = nominalFPS > 0 ? nominalFPS : 30.0
    // NTSC ドロップフレーム対応
    switch fps {
    case 23.9...24.0:   resolvedFrameDuration = CMTime(value: 1001, timescale: 24000)
    case 29.9...30.0:   resolvedFrameDuration = CMTime(value: 1001, timescale: 30000)
    case 59.9...60.0:   resolvedFrameDuration = CMTime(value: 1001, timescale: 60000)
    default:            resolvedFrameDuration = CMTimeMake(value: 1, timescale: Int32(fps.rounded()))
    }
} else {
    resolvedFrameDuration = settings.frameRate.frameDuration
}
```

**NTSC 対応**: `nominalFrameRate` が 23.976 / 29.97 / 59.94 の場合は `1001/24000` / `1001/30000` / `1001/60000` を使用し、非 NTSC は `1/round(fps)` にフォールバック。

---

### 11. `containsTweening = true` — フレームレート変換の致命的修正（Phase 14）

**対象**: `CustomVideoCompositionInstruction.swift`

**症状**: FPS を 30fps に設定しても出力が 23.976fps のまま。ログで `resolvedFrameDuration = 1/30`、`videoComposition.frameDuration = 1/30` と正しく設定されているにもかかわらず、出力 FPS が変わらない。

**根本原因**: `AVVideoCompositionInstructionProtocol` の `containsTweening` プロパティが `false` だった。

```swift
// 変更前
var containsTweening: Bool { false }

// 変更後
var containsTweening: Bool { true }
```

**技術的背景**:

- `containsTweening = false` の場合、AVFoundation は「このインストラクションはソースフレームの 1:1 パススルーであり、フレーム間補間は不要」と解釈する
- この場合の最適化として、AVFoundation は `videoComposition.frameDuration` を**無視**し、ソースフレームのタイムスタンプでのみコンポジターを呼び出す
- `containsTweening = true` にすることで、AVFoundation は `frameDuration` 間隔でコンポジターを呼び出し、フレームレート変換が正しく動作する

**補足 — フレーム補間は発生しない**:

`containsTweening = true` でも実際の光学フロー補間は行われない。AVFoundation は最近傍フレーム（nearest-neighbor）を使う:
- ソースより高い fps 設定 → 同一フレームが繰り返される（フレームリピート）
- ソースより低い fps 設定 → フレームがスキップされる

これはフレームレート変換としては標準的な挙動であり、品質上の懸念はない。

---

### 12. 動的 ExpectedSourceFrameRate（Phase 14）

**対象**: `VideoProcessor.swift`

`AVVideoExpectedSourceFrameRateKey`（HW エンコードパス）と `kVTCompressionPropertyKey_ExpectedFrameRate`（SW VT パス）が以前はハードコード 30 だったのを、実際の出力 FPS に連動するよう変更。

```swift
let outputFPS = 1.0 / resolvedFrameDuration.seconds

// HW パス (AVAssetWriter)
videoSettings[AVVideoExpectedSourceFrameRateKey] = outputFPS

// SW パス (VTCompressionSession) — ABR 時のみ
VTSessionSetProperty(compSession,
    key: kVTCompressionPropertyKey_ExpectedFrameRate,
    value: NSNumber(value: outputFPS))
```

**影響**: エンコーダの内部バッファ管理とビットレート制御が実際の FPS に最適化される。24fps 入力を 24fps で維持する場合、ExpectedFrameRate=30 だとビットレート配分が不正確になっていた。

---

### 13. Crop ラベル 4:3/3:4 反転修正（Phase 13）

**対象**: `CustomVideoCompositionInstruction.swift`

```swift
// 変更前（誤）
case centerPortrait4x3: return "4:3"   // 実際は被写体を 3:4 でクロップ
case centerPortrait3x4: return "3:4"   // 実際は被写体を 4:3 でクロップ

// 変更後（正）
case centerPortrait4x3: return "3:4"
case centerPortrait3x4: return "4:3"
```

`centerPortrait4x3` は 4:3 **ソースを** 3:4 **ポートレートにクロップ**するため、UI上の表示は "3:4" が正しい。

---

### 14. 設定行ツールチップ（Phase 13）

**対象**: `ContentView.swift`

`settingRow()` ヘルパーに `tooltip: String = ""` パラメータを追加し、外側の HStack に `.help(tooltip)` を適用。

```swift
private func settingRow<Content: View>(
    _ label: String,
    tooltip: String = "",
    @ViewBuilder content: () -> Content
) -> some View {
    HStack {
        // ...
    }
    .help(tooltip)
}
```

**`.help()` の配置**: 当初は内側のラベル HStack（115pt 幅）に配置していたが、ヒットエリアが狭くホバーが困難だったため、外側の行全体の HStack に移動。行のどこにマウスを置いてもツールチップが表示される。

追加したツールチップ（全 9 行、英語）:

| 設定行 | ツールチップ |
|--------|------------|
| Resolution | Output vertical resolution |
| FPS | Output frame rate (Src = keep source) |
| Codec | Video codec and encoder type |
| Container | Output file container format |
| Bitrate | Target video bitrate |
| Bitrate Mode | VBR / CBR / ABR encoding strategy |
| Crop | How the 16:9 source is cropped to 9:16 |
| Follow Speed | Smart Framing camera follow speed |
| Tone Map | HDR→SDR tone mapping algorithm |

---

### 15. プログレスバー UI スペーシング（Phase 15）

**対象**: `ContentView.swift`

プログレスバーとステータステキスト間の余白を縮小。外側 `VStack(spacing: 14)` 内でプログレスバーとテキストを `VStack(spacing: 2)` でラップ。

```swift
VStack(spacing: 14) {
    // ... other content ...
    VStack(spacing: 2) {
        ProgressView(value: viewModel.progress)
        Text(viewModel.statusText)
    }
}
```

---

### 16. About ウィンドウ（Phase 12, 15）

**対象**: `VerticalConverterApp.swift`

`CommandGroup(replacing: .appInfo)` で標準 About メニューを置き換え。HTML credits で GitHub / X リンクとライセンス情報を表示。

```swift
CommandGroup(replacing: .appInfo) {
    Button("About Vertical Converter") {
        let credits = NSAttributedString(
            html: Data("""
            <div style="...">
                <a href="https://github.com/YOURNAME/VerticalConverter">GitHub</a> · <a href="https://x.com/YOURHANDLE">X</a>
                <br><br>
                MIT License + Commons Clause © 2026 shoma<br>
                This software may not be sold.<br>
                See LICENSE for details.
            </div>
            """.utf8),
            documentAttributes: nil
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits as Any
        ])
    }
}
```

---

### 17. README 多言語ナビゲーション（Phase 15）

**対象**: `README.md`

冒頭に `📖 English | 📖 日本語` リンクを追加。HTML アンカー (`<h2 id="english">`, `<h2 id="日本語">`) でジャンプ。

- 全セクション（Features / Technical Specs / Build / Usage / Project Structure / Architecture / Details / Notes / Roadmap / Changelog / License）を英訳
- 各言語セクション末尾に「⬆ Back to top / ⬆ トップへ戻る」リンクで自セクション先頭に戻るナビゲーション
- `<details>` 折りたたみ内の Smart Framing / HDR / Implementation Notes も完全英訳

### 18. Vision リクエストキャッシュ最適化のリバート（Phase 17, 03-13）

**対象**: `SmartFramingAnalyzer.swift`, `VerticalVideoCompositor.swift`

**経緯**: Phase 15 で `VNDetectHumanBodyPoseRequest` / `VNDetectFaceRectanglesRequest` をフレームごとに生成する代わりに、ループ外で一度だけ生成して再利用する最適化を実装した。メモリ消費・CPU 負荷の軽減が目的だった。

**問題**: ユーザーテストで Smart Framing の検出精度が低下（「挙動が甘くなった」）。人物追従の精度が目に見えて悪化した。

**原因**: `VNRequest` サブクラス（`VNDetectHumanBodyPoseRequest` / `VNDetectFaceRectanglesRequest`）は内部に CoreML モデルセッション状態を保持する。フレーム間でインスタンスを再利用すると、前フレームの内部バッファが次フレームの検出精度に干渉する。Apple のドキュメントではリクエストの再利用について明確な禁止はないが、実際にはフレームごとの fresh な `VNRequest` 生成が想定された使い方である。

**修正**: 両ファイルを最適化前の状態に完全リバート。

- `SmartFramingAnalyzer.detectRawPersons(in:)`: パラメータから `bodyRequest` / `faceRequest` を削除し、メソッド内でフレームごとに `VNRequest` を新規生成するように復元
- `VerticalVideoCompositor`: `cachedBodyRequest` / `cachedFaceRequest` インスタンスプロパティを削除。`detectPersonNormalizedX(in:)` 内でフレームごとに `VNRequest` を新規生成するように復元

**教訓**: Vision の `VNRequest` は軽量オブジェクトではなく、内部に CoreML 推論セッション・中間バッファを持つ。パフォーマンス最適化としてのインスタンス再利用は検出品質を犠牲にするリスクがある。Apple の Vision フレームワークではリクエストのフレームごと生成がベストプラクティス。

### Phase 16: About ウィンドウ ライセンス表示修正

**対象**: `VerticalConverterApp.swift` — `AboutView.licenseText`

**問題**: LICENSE ファイルをバンドルから読み込んで `Text` に渡すと、ファイル内の80文字折り返しがそのまま表示され、ウィンドウ幅に対して不自然な改行が多発していた。

**原因**: テキストファイルの改行コード（`\n`）を SwiftUI の `Text` がそのまま改行として扱うため、ファイルの行幅（80文字）で強制改行される。`Text` の折り返しは画面幅に委ねる必要がある。

**修正**: `normalizeLicense()` 関数を追加。段落（`\n\n` 区切り）単位で分割し、段落内の `\n` を空白に置換してから再結合することで、SwiftUI が画面幅に合わせて自然に折り返せるプレーンテキストに変換する。
```swift
private static func normalizeLicense(_ text: String) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")
    return paragraphs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  .replacingOccurrences(of: "\n", with: " ") }
        .joined(separator: "\n\n")
}
```

**エディション別の対応**:

| エディション | ライセンス表示内容 |
|---|---|
| AppStore | MIT 本文（ハードコード）+ Commons Clause はソースコードのライセンスである旨の注記 + GitHub リンク |
| Direct / Demo | LICENSE ファイルを読み込み → `normalizeLicense()` で正規化。読み込み失敗時は MIT + Commons Clause 全文をハードコードフォールバック |

**DemoUsageTracker の AppStore ビルド除外**:

同セッションで `DemoUsageTracker` クラスおよびその参照箇所（`BuildEdition.showsWatermark`・`ContentView.demoStatusLabel`）を `#if EDITION_DEMO` / `#endif` で囲み、AppStore ビルドのバイナリから完全除外した。`strings` コマンドで `DemoWindowStartDate` 等のキー文字列が出力されないことを確認済み。
```bash
# 確認コマンド
strings VerticalConverter_AppStore.app/Contents/MacOS/VerticalConverter | grep -i "demo"
# → 何も出力されないことを確認
```

---
---

# v1.0.2 機能追加メモ

**日付**: 2026-03-14

---

## セッション経緯

### Phase 19: クロップ位置調整機能（03-14）

Preview ウィンドウにクロップの横位置を調整するスライダーを追加。Fit H / Square / 4:3 / 3:4 モードでクロップ中心を左右にシフト可能。Fit W モードでは横シフトが意味をなさないため、スライダーは`.opacity(0.35)` + `.allowsHitTesting(false)` でグレーアウト表示。

**変更ファイル**:

| ファイル | 変更内容 |
|---------|---------|
| `CustomVideoCompositionInstruction.swift` | `cropPositionX: CGFloat = 0.5` / `cropPositionY: CGFloat = 0.5` プロパティ追加 |
| `VerticalVideoCompositor.swift` | `cropPositionX` / `cropPositionY` インスタンス変数追加、`makeLetterboxImage()` でクロップ位置オフセットを適用 |
| `VideoProcessor.swift` | `convertToVertical()` / `createComposition()` に `cropPositionX` / `cropPositionY` パラメータ追加 |
| `ContentView.swift` | `ContentViewModel` に `cropPositionX` / `cropPositionY` 追加、Preview シートにスライダー UI、`CropPreviewView` / `CropPreviewThumbnail` にバインディング追加 |

**技術的詳細**:

- 縦位置（`cropPositionY`）は内部的に保持するが UI には露出しない（将来の拡張用）
- `CropPreviewThumbnail.croppedImage()` は `AnyView` 型消去で fitWidth / fitHeight / center crop の 3 分岐を処理
- 新規ファイル選択時に `cropPositionX = 0.5; cropPositionY = 0.5` にリセット

### Phase 20: 設定の永続化（03-14）

全変換設定を UserDefaults で保存し、次回起動時に自動復元する機能を追加。

**変更ファイル**:

| ファイル | 変更内容 |
|---------|---------|
| `ContentView.swift` | `SettingsKey` enum、`saveSettings()` / `restoreSettings()` メソッド、全 Published プロパティに `didSet { saveSettings() }` |
| `ContentView.swift` | `saveOutputDirectoryBookmark()` / `restoreOutputDirectoryBookmark()` — Security-Scoped Bookmark による出力フォルダ永続化 |
| `VerticalConverter_AppStore.entitlements` | `com.apple.security.files.bookmarks.app-scope = true` 追加 |
| `PrivacyInfo.xcprivacy` | `NSPrivacyAccessedAPICategoryUserDefaults`（理由: CA92.1）を追加 |

**技術的詳細**:

- `isRestoringSettings` フラグで `restoreSettings()` 中の `didSet` による再帰的 `saveSettings()` 呼び出しを抑制
- Security-Scoped Bookmark: `URL.bookmarkData(options: .withSecurityScope)` で作成、`URL(resolvingBookmarkDataWithOptions: .withSecurityScope)` で復元、`startAccessingSecurityScopedResource()` でアクセス権取得
- Demo 版の `DemoWindowStartDate` / `DemoEncodeCount` とはキープレフィックスが異なる（`vc_` プレフィックス）ため干渉しない

---
---

# v1.0.2 Smart Framing 改善・MPEG-TS 調査メモ

**日付**: 2026-03-19 〜 2026-03-20

---

## セッション経緯

### Phase 21: Vision 解析の大入力問題 — 縮小処理追加（03-19）

4K や 1440×1080 AVCHD など大きな入力に対して Vision の人物検出リクエストが不安定・低速になる問題を確認。

**修正**:
- `SmartFramingAnalyzer.swift`: `analysisMaxDimension = 960` を導入。入力の長辺が960pxを超える場合は `CIImage → CGImage` 経由でリサイズしてから Vision に渡す。スケール係数を `analysisScale` として記録し、検出座標を元のスケールに戻す。
- `VerticalVideoCompositor.swift`（リアルタイムフォールバック）: `detectPersonNormalizedX()` にも同様の縮小パスを追加（既存 CIContext を使用）。

**技術的ポイント**:
```swift
// SmartFramingAnalyzer.swift
private let analysisMaxDimension: CGFloat = 960.0
// detectRawPersons() 内
let longSide = max(CGFloat(width), CGFloat(height))
let analysisScale: CGFloat = longSide > analysisMaxDimension
    ? analysisMaxDimension / longSide : 1.0
// CIImage → CGImage downscale → VNImageRequestHandler
```

---

### Phase 22: PAR（非正方形ピクセル）対応（03-19）

AVCHD 1440×1080（PAR 4:3 → DAR 16:9）を入力したとき、`naturalSize` がピクセル寸法（1440×1080）を返し正しい表示比率にならない問題を修正。

**修正**:

| ファイル | 変更内容 |
|---------|---------|
| `VideoProcessor.swift` | `inputSize` の計算を `CMVideoFormatDescriptionGetPresentationDimensions(usePixelAspectRatio: true)` に変更 |
| `VerticalVideoCompositor.swift` | `composeFrame()` で `staticInputSize`（表示寸法）と `sourceImage.extent`（ピクセル寸法）が異なる場合にアフィン拡大変換を適用して PAR 補正 |

**ログ出力**（PAR補正が働いた場合）:
```
VideoProcessor: PAR correction — pixel 1440×1080 → display 1920×1080
```

```swift
// VerticalVideoCompositor.swift — composeFrame()
let bufferSize = CGSize(width: sourceImage.extent.width, height: sourceImage.extent.height)
let displaySize = VerticalVideoCompositor.staticInputSize
if abs(bufferSize.width - displaySize.width) > 1 || abs(bufferSize.height - displaySize.height) > 1 {
    let sx = displaySize.width  / bufferSize.width
    let sy = displaySize.height / bufferSize.height
    sourceImage = sourceImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
}
```

---

### Phase 23: MPEG-TS 入力（.mts）調査と remux 試み（03-19〜20）

AVCHD と同じ映像（AVC High@L4.1 + MBAFF インターレース）を MPEG-TS に格納した `.mts` ファイルで Smart Framing が動作しない問題を調査。同内容の mp4 では正常動作。

**症状**:
```
VerticalVideoCompositor: FAILED - sourceFrame is nil for trackID=1
VideoProcessor: reader failed: sourceFrame nil for trackID=1
```

**remux 試み**: `.mts` を一度 `.mov` に passthrough remux してから `AVAsset` を作成するパイプラインを実装（`remuxTSContainerToMov()`）。しかし合成時の `sourceFrame` nil は解消せず。

**原因候補**（調査中の仮説）:
- MBAFF（インターレース）デコーダが最初のフレームを `AVVideoCompositing` のタイムライン上で利用可能にするまでバッファが存在しない
- trackID 不一致：remux 後の trackID と `AVVideoCompositionLayerInstruction.trackID` が一致しない可能性
- `alwaysCopiesSampleData = false`（passthrough）でバッファが内部的に早期解放される

**安定化対処（暫定）**: `VerticalVideoCompositor.composeFrame()` で `sourceFrame(byTrackID:)` を最大3回リトライする処理を追加。根本解決には至らなかった。

---

### Phase 24: MPEG-TS 入力を早期リジェクトに方針変更（03-20）

remux パイプラインを維持しても安定しないことが確認できず、パイプライン全体のリスクを高めるとの判断から、`.mts/.m2ts/.ts` のリジェクトに切り替え。

**修正** (`VideoProcessor.swift`):
```swift
// 入力バリデーション冒頭
let ext = inputURL.pathExtension.lowercased()
if ["mts", "m2ts", "ts"].contains(ext) {
    NSLog("VideoProcessor: rejected input container (.%@) — only MP4/AVCHD is accepted.", ext)
    throw VideoProcessorError.unsupportedFormat
}
```

**理由**:
- 同内容を mp4 に変換済みであれば通常の AVCHD パスで正常動作する
- MPEG-TS の AVFoundation 読み出しの不安定さは Apple の既知の制約事項
- remux 目的で `AVAssetReader/Writer` を追加することで Swift concurrency / `CancelToken` Sendable 問題が副次的に発生した（→下記 Phase 25 で修正）

---

### Phase 25: Swift concurrency コンパイルエラー修正（03-20）

remux 関連コードを追加した際、並列クロージャ内でのミュータブル変数キャプチャが Swift 6 の並行性ルールに違反してコンパイルエラーになった。

**修正**:

| 修正内容 | 変更箇所 |
|---------|---------|
| `CancelToken` を `@unchecked Sendable` に昇格 | `VideoProcessor.swift` |
| `videoInput` / `audioInput` を不変ローカルで明示キャプチャ | `VideoProcessor.swift` |
| `CMFormatDescription` への条件付きキャストが常に成功する警告を除去 | `VideoProcessor.swift` |

```swift
// CancelToken に Sendable を付与
final class CancelToken: @unchecked Sendable { ... }

// キャンセルハンドラ用に不変キャプチャ
let cancelVideoInput = videoInput
let cancelAudioInput = audioInput
```

---

### Phase 26: リサーチ結果（03-20）

#### App Sandbox / mutex パイプラインの App Store ガイドライン適合性

- **プロセス内同期**（`DispatchQueue` / `NSLock` / `pthread_mutex` 等）は App Sandbox 内でも問題なし。
- **禁止事項**: 名前付き POSIX セマフォ（`sem_open`）・名前付き共有メモリ・ヘルパー外部プロセス起動・権限昇格・プライベートAPI使用。
- **ファイルアクセス**: ファイルロック（`flock` / `fcntl`）はアプリコンテナ内かユーザーが選択した Security-Scoped Bookmark のパスのみ許可。コンテナ外の任意パスへの書き込みは失敗する。
- **本プロジェクトの remux パイプラインで使用している DispatchQueue / NSLock は問題なし**。remux の出力先として `FileManager.default.temporaryDirectory` を使っているが、App Sandbox ではこれはコンテナ内 tmp に向くため可。

#### VarFPS（可変フレームレート）入力時の挙動

- AVFoundation は PTS + duration ベースのため VarFPS は扱えるが、`AVVideoComposition.frameDuration` を設定すると出力は固定FPSになる。
- カスタムコンポジタは `frameDuration` 間隔で呼ばれるため、VarFPS 入力では最近傍フレームが選ばれる（フレームリピートまたはドロップ）。
- `VTCompressionSessionEncodeFrame` に正確な PTS と duration を渡すことで圧縮側は対応可能。
- **現状のパイプラインに VarFPS の特別対応はない**。入力 FPS を `nominalFrameRate` で読むため、大きな FPS 変動があるコンテンツは先頭付近の FPS を出力 FPS として固定することになる。必要なら入力にフレームスタンプを走査して平均/最頻 FPS を計算するプリパス追加が有効。

---

## 未解決事項・今後の検討

| 課題 | 状況 | 優先度 |
|------|------|--------|
| `.mts` 入力サポート | 早期リジェクト（`unsupportedFormat`）で対処。根本原因調査は保留 | 低 |
| VarFPS 入力の精度向上 | 現状は `nominalFrameRate` ベースの固定FPS処理 | 低 |
| MPEG-TS の `sourceFrame is nil` 根本原因 | trackID不一致・インターレースバッファ遅延・passthrough解放の3候補 | 保留 |
| 合成時の3回リトライ処理 | `.mts` 拒否後も残存。改修機会に削除を検討 | 低 |

---

### Phase 27: UI改善・クロップ位置スライダー再設計（03-20）

#### 変更概要

| 変更内容 | 詳細 |
|---------|------|
| クロップ位置スライダーをメインパネルに移動 | バッチモードでもアクセス可能に。動画未読み込み時・Fit W・Smart Framing ON 時はグレーアウト |
| リセットボタンをアイコン化 | `Button("Reset")` → `arrow.counterclockwise` アイコン。スライダー右端へ移動（Output 行の `xmark.circle.fill` と位置を統一） |
| メインパネルラベルを "Center Pos" に短縮 | 1行に収まりHStackが折り返さないようにした |
| Preview パネルラベルを "Center Position" + `arrow.left.and.right` アイコンに統一 | リセットボタンも `arrow.counterclockwise` アイコンに統一 |
| Center Pos・Output 行を `settingRow` ヘルパー経由に統一 | それまで手書き複製していたHStack構造を排除 |
| 全行に `.frame(minHeight: 30)` を追加 | Resolution〜Output の全行高さを統一 |
| ヘッダーのバージョン文字列を削除 | `Text("v\(Bundle.main...)")` を除去。上部 padding を 22→14pt に調整 |

#### 設計判断

- Preview シートのスライダーは残したまま（プレビュー確認しながら微調整できるため）
- メインパネルのスライダーはバッチモード時の唯一の調整手段
- `settingRow` への統一により将来の行追加・スタイル変更が一箇所で済む
