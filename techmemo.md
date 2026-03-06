# VerticalConverter HDR 修正・改修メモ

**日付**: 2026-03-06

---

## セッション経緯

### Phase 1: バグ報告・コードベース解析

HDR 素材を扱う際に以下 3 つのバグが報告された。全ソースファイル（`VideoProcessor.swift`, `VerticalVideoCompositor.swift`, `VideoExportSettings.swift`, `CustomVideoCompositionInstruction.swift`, `ContentView.swift`）を通読し、根本原因を特定した。

### Phase 2: 第 1 次修正（失敗）

- `CIContext` の `workingColorSpace` を `extendedLinearSRGB` → **`extendedLinearITUR_2020`** に変更
- HEVC コンテナを `.mp4` → `.mov` に変更
- `staticInputSize` 導入、VTB フラッシュに `CMTime.invalid` 使用

**結果**: ユーザーから「HDR パススルーの色は改善せず、H.265 (SW) はむしろ悪化」と報告。スクリーンショットではブラー背景がシアン（上部）とオレンジ（下部）に完全に壊れていた。`extendedLinearITUR_2020` は Metal パイプライン内部でフィルタ処理中に想定外の色空間変換を引き起こしていた。

### Phase 3: 第 2 次修正（現行コード）

- `extendedLinearITUR_2020` を撤回し、HDR パススルー時は **`NSNull()`**（カラーマネジメント完全無効化）に変更
- `composeFrame()` のソース画像生成・レンダリングも `colorSpace` なしに統一
- `.mov` コンテナ変更、`staticInputSize`、VTB フラッシュ改善は第 1 次から維持

**状態**: コード適用済み・ユーザー未検証

### Phase 4: libplacebo フィジビリティ調査

自前 HDR→SDR トーンマッピングの品質問題が根本にあるため、libplacebo への置換を検討。GitHub README、`tone_mapping.h`、`shaders/colorspace.h`、CI 設定、Homebrew formula を調査し、「技術的には可能だが統合コスト・ライセンス制約から非推奨」と結論。

### Phase 5: 今後の方針決定

libplacebo を見送り、現実的な選択肢として (1) `CIToneMapHeadroom` 一本化、(2) Metal Compute Shader 自前実装 を今後の候補とした。

---

## 報告されたバグ

HDR 素材を扱う際に以下 3 つのバグが報告された。

| # | 症状 | 原因 |
|---|------|------|
| 1 | HDR パススルー（変換なし）で色が変わる | `CIContext` の `workingColorSpace` が `extendedLinearSRGB` のため BT.2020→sRGB→BT.2020 のガマット往復が発生し、特にブラー背景で色相が大きくシフトする |
| 2 | H.265 (SW) 書き出しが QuickLook / QTX で再生不可 | Software HEVC エンコーダの出力を `.mp4` コンテナに入れていたため、macOS の QuickLook/QTX が Main10 HDR メタデータを正しく解釈できなかった |
| 3 | H.264 (SW) 以外の書き出しでフレーム 0 のガンマが狂う | `CIContext` / Metal の内部状態（シェーダーコンパイル・テクスチャキャッシュ・IOSurface バッキング）がフレーム 0 到着時に lazy init され、本番フレームとは異なる Metal パスが走る |

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

## 今後の予定（現実的な選択肢）

### 選択肢 1: `CIToneMapHeadroom` 一本化（macOS 15+ / iOS 18+）

Apple 標準トーンマッピングフィルタに Natural / Cinematic 両方を寄せる案。

- **実装内容**:
  - `applyToneMapping()` で Natural モードも `CIToneMapHeadroom` を使用（現在は Reinhard カーネルにフォールバック）
  - `sourceHeadroom` パラメータで HLG（4.0）/ PQ（16.0）を切り替え
  - `targetHeadroom` を 1.0（SDR）固定
  - macOS 14 以下は既存 Reinhard / ACES カーネルをフォールバック維持
- **メリット**:
  - Apple の内部 Metal シェーダーが BT.2390 準拠のトーンマッピング + ガマットマッピングを行う
  - カラーマネジメントとの整合性が高く、CIContext の workingColorSpace との相性問題が少ない
  - 追加依存ゼロ・コード変更最小
- **デメリット**:
  - macOS 15+ 限定（macOS 14 は既存カーネルのまま）
  - Natural / Cinematic の見た目の差が小さくなる可能性
- **工数**: 小（`applyToneMapping()` の分岐修正のみ）

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
