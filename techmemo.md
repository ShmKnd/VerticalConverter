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

macOS 15+ では Natural / Cinematic **両方**で `CIToneMapHeadroom` を使用。macOS 14以下は Reinhard（Natural）/ ACES（Cinematic）にフォールバック。

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
