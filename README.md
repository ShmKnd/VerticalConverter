# Vertical Converter

16:9の横長動画をYouTubeショート/リール用の縦型動画（9:16）に変換するmacOSアプリです。

---

## 機能

| 機能 | 説明 |
|---|---|
| ドラッグ&ドロップ | 動画ファイルをウィンドウにドロップするだけで選択（複数ファイル対応） |
| **バッチ変換** | 複数ファイルを一括選択し、順番に自動変換 |
| **スマートフレーミング** | Visionで人物を事前解析し、被写体を追従しながら縦クロップ |
| **IOUトラッキング** | 複数人物を個別追跡し、主役（長時間・安定）を自動推定 |
| **Y方向ヘッドルーム制御** | 上半身・ダンス等でも頭の余白を自動確保 |
| **クロップモード** | Fit W / Fit H / Square / 4:3 / 3:4 の5種類から選択 |
| **クロッププレビュー** | サムネイル時刻シークつきのプレビューシートでクロップ結果を事前確認 |
| **HDR→SDR変換** | Natural / Cinematic トーンマッピング（macOS 15+: CIToneMapHeadroom、macOS 14: Reinhard/ACES フォールバック） |
| **HDR パススルー** | HDR メタデータ（HLG/PQ/BT.2020）を保持したまま縦変換。HEVC エンコーダ向け整数フォーマット最適化あり |
| コーデック選択 | H.264 / H.265 / H.264 (VT) / H.265 (VT) / ProRes422 (VT) |
| **コンテナ選択** | HEVC 出力時に MOV / MP4 を選択可能（H.264 は MP4 固定、ProRes は MOV 固定） |
| 解像度選択 | 720p (720×1280) / 1080p (1080×1920) |
| フレームレート選択 | 24 / 29.97 DF / 30 / 60 fps |
| ビットレート選択 | 8 / 10 / 12 Mbps |
| ビットレートモード | VBR / CBR / ABR |
| **hev1自動リマックス** | hev1入力を品質劣化なしでhvc1へ自動リマックスしてから処理 |
| **非対応コーデック検知** | DNxHD/DNxHR 入力を早期検知しエラーを返す |
| キャンセル | 変換中断ボタン |
| Dockプログレス | Dockアイコンにプログレスバー表示 |

---

## 技術仕様

- **対応OS**: macOS 14.0以降
- **言語**: Swift / SwiftUI
- **フレームワーク**: AVFoundation, Vision, Core Image, VideoToolbox
- **処理方式**: 2パス（解析→変換）、スマートフレーミングOFF時は1パス
- **出力形式**: MP4（H.264 + AAC 192kbps）、MOV または MP4（H.265 + AAC 192kbps）、MOV（ProRes422）
- **出力解像度**: 720×1280 または 1080×1920（9:16）

---

## ビルド方法

```bash
cd VerticalConverter
open VerticalConverter.xcodeproj
# Xcode で ⌘+B または ⌘+R
```

---

## 使用方法

1. 動画ファイルをウィンドウにドラッグ（複数可）、またはクリックして選択
2. 設定パネルで解像度・FPS・コーデック・ビットレート・ビットレートモード・クロップモードを選択
3. （オプション）「Preview」ボタンでクロップ結果をプレビュー、サムネイル時刻をシークして確認
4. （オプション）スマートフレーミングパネルでON/OFF・追従速度を設定
5. （オプション）HDR→SDR変換パネルでON/OFF・トーンマッピングモードを設定
6. 「Start Conversion」（バッチ時は「Start Batch Conversion」）ボタンをクリック
7. 変換完了後、Finderで保存先が自動表示される

---

## プロジェクト構造

```
VerticalConverter/
├── VerticalConverterApp.swift              # エントリーポイント
├── ContentView.swift                       # メインUI + ContentViewModel（バッチ対応）
├── VideoProcessor.swift                    # 変換オーケストレーション（hev1 リマックス + 2パス）
├── VideoExportSettings.swift               # エクスポート設定（解像度・FPS・コーデック・コンテナ・モード）
├── SmartFramingSettings.swift              # スマートフレーミング設定
├── SmartFramingAnalyzer.swift              # 第1パス: Vision解析 + IOUトラッキング
├── VerticalVideoCompositor.swift           # 第2パス: カスタムフレーム合成 + HDRトーンマッピング
├── CustomVideoCompositionInstruction.swift # AVVideoCompositionInstruction実装（LetterboxMode・ToneMappingMode定義）
└── DockProgress.swift                      # Dockプログレスバー
```

---

## アーキテクチャ

### 処理フロー

```
[前処理（必要時のみ）]
  hev1 入力検出 → hvc1 へリマックス（再エンコードなし、品質劣化なし）
  DNxHD/DNxHR 入力検出 → 早期エラー
  ProRes 入力検出 → ログ出力（macOSネイティブデコード可）
  HDR メタデータ検出（TransferFunction / ColorPrimaries / YCbCrMatrix）

[第1パス: SmartFramingAnalyzer]（スマートフレーミングON時のみ）
  入力動画を全フレームスキャン
    → 人物検出（VNDetectHumanBodyPoseRequest + VNDetectFaceRectanglesRequest）
    → IOUトラッキング（PersonTracker）
    → 主役スコア計算
    → X/Y 正規化座標を記録
    → 線形補間（検出間フレームを補完）
    → EMA（指数移動平均）スムージング（因果的 IIR、fps依存 α）
    → ホールド＆フォロー（X: 3秒ホールド / Y: 0.5秒ホールド）
    → precomputedOffsets: [CGPoint] を出力

[第2パス: VerticalVideoCompositor]
  フレームごとに precomputedOffsets[i] を参照
    → scale × (offsetX, offsetY) を適用してクロップ
    → スマートフレーミングOFFの場合はレターボックス（選択クロップモード）+ブラー背景
    → HDR→SDR ON の場合はトーンマッピング適用（macOS 15+: CIToneMapHeadroom / macOS 14: Natural: Reinhard / Cinematic: ACES）

[エンコード]
  H.264 / H.265（非VT）→ VTCompressionSession によるソフトウェアエンコード
  H.264 (VT) / H.265 (VT) → AVAssetWriter によるハードウェアエンコード
  ProRes422 (VT) → AVAssetWriter（ハードウェアエンコーダ有無を事前チェック）
  オーディオ → AAC 192kbps
```

---

## スマートフレーミング詳細

### ① fps依存 EMA（指数移動平均）

```
α = 1 / (1 + fps × 0.2)
// 24fps → α ≈ 0.17（直近フレームに17%の重み）
// 30fps → α ≈ 0.14（直近フレームに14%の重み）
// 60fps → α ≈ 0.08（直近フレームに8%の重み）
y[n] = α·x[n] + (1-α)·y[n-1]
```

IIR フィルタ（EMA）による因果的スムージング。過去のみを参照し、直近フレームに重みを集中させ、古い情報は指数的に減衰させる。双方向ガウシアンは未来フレームを参照し「被写体が動く前にカメラが先読みでパンする」不自然な挙動を生むため、EMA で置換した。holdAndFollow (Step 4) も EMA 的追従のため、パイプライン全体で一貫した指数減衰モデルとなる。

---

### ② IOUトラッキング + 主役推定

```
検出 → PersonTracker（IOUマッチング）→ subjectScore 計算 → 加重中心
```

#### PersonTracker

- IOU ≥ 0.20 でグリーディマッチング
- 連続5検出間隔（≈40フレーム）未検出で削除
- 各トラックに `lifespan`（累計検出回数）・`velocities`（直近6サンプルの移動量）を蓄積

#### subjectScore（主役らしさ）

$$\text{score} = \text{confidence} \times \underbrace{\max(0.2,\ 1 - |x{-}0.5| \times 1.6)}_{\text{centrality}} \times \underbrace{\min\!\left(1,\ \frac{\text{lifespan}}{fps \times 1.5}\right)}_{\text{lifespanWeight}} \times \underbrace{\frac{1}{1 + v \times 6}}_{\text{motionWeight}}$$

| ケース | 結果 |
|---|---|
| **グループ3人（等価）** | 全員が長寿命・低速度 → 全員高スコア → グループ中心を追う |
| **主役＋通過者** | 通過者は短命・高速 → motionWeight + lifespanWeight が激減 → 主役が支配的 |

---

### ③ 適応的検出間隔

```swift
let deviation = hypot(center.x - lastCenter.x, center.y - lastCenter.y)
detectionInterval = deviation > 0.10 ? 4 : 8
```

激しい動き（ダンス・スポーツ）では4フレーム毎に自動短縮。

---

### ④ Y方向ヘッドルーム制御

```
yZoomFactor = 1.1   // 10%ズームインでY方向パン余白を確保
targetRatio = 0.80  // 下から80%（上から20%）の位置に上半身を配置
deadZoneRatio = 0.08
minHoldFrames = fps × 0.5秒
```

ダンス・トーク動画で頭が切れず、上半身が自然なヘッドルームで収まる。

---

## HDR→SDR変換

### トーンマッピングモード

| モード | 説明 |
|---|---|
| **Natural** | macOS 15+: `CIToneMapHeadroom`。macOS 14: Reinhard extended + ハイライト彩度抑制。Rec.709/sRGB に忠実な自然な色味。 |
| **Cinematic** | macOS 15+: `CIToneMapHeadroom`。macOS 14: ACES filmic カーブ。コントラスト高めのフィルムライクな仕上がり。 |

### 技術的な処理フロー

1. 入力トラックのフォーマット記述から TransferFunction / ColorPrimaries / YCbCrMatrix を検出
2. `AVMutableVideoComposition` に検出した色空間プロパティを設定（AVFoundation の暗黙変換を防止）
3. `VerticalVideoCompositor` の static プロパティに HDR メタデータを設定
4. ソースピクセルバッファを非線形 HLG/PQ カラースペースでタグ付け → CIContext が逆 OETF を適用して線形値に変換
5. トーンマッピング（macOS 15+: `CIToneMapHeadroom`、macOS 14: CIColorKernel）で HDR 値を [0, 1] に圧縮
6. Rec.709 カラースペースで SDR 出力にレンダリング

### HDR パススルー

HDR→SDR 変換を無効にした場合、HDR メタデータ（HLG/PQ/BT.2020）を保持したまま縦変換を行う。

- `CIContext` に `NSNull()` workingColorSpace を設定し、カラーマネジメントを完全無効化
- HEVC エンコーダへの入力は `32BGRA`（8bit 整数）フォーマット（float 入力での二重 OETF を回避）
- H.264 / ProRes は `64RGBAHalf`（16bit float）で HDR 値の精度を最大化

### CIContext のウォームアップ（Frame 0 問題の解決）

`renderContextChanged` で本番の `ciContext` を使って dummy バッファに対し `composeFrame` を2回実行し、Metal シェーダーコンパイル・テクスチャキャッシュ・IOSurface バッキングを事前に初期化。これにより frame 0 でのガンマ/色ずれを防止。

### AVMutableVideoComposition の色空間プロパティ

`videoComposition.colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix` をソース HDR メタデータに合わせて設定。未設定の場合、AVFoundation がデフォルト BT.709 を想定し、BT.2020 HDR フレームに暗黙の色空間変換を適用してコンポジターに渡すため、彩度が変化する。全 HDR 入力（パススルー・HDR→SDR 問わず）に対してソースプロパティを設定することで、AVFoundation が未変換のフレームを直接コンポジターに渡す。

### HEVC HDR パススルーのピクセルフォーマット最適化

Apple の HEVC エンコーダ（SW/HW 両方）は `64RGBAHalf`（float）入力を scene-linear と解釈し、HLG/PQ 転送関数がセットされていると OETF を適用する。NSNull CIContext からの値は既に OETF エンコード済みのため、二重適用でダイナミックレンジが圧縮される。HEVC HDR パススルー時はコンポジター出力を `32BGRA`（8bit 整数）にすることで、エンコーダが display-referred として扱い OETF を適用しない。H.264 / ProRes は HDR 対応パイプラインを持たないため float のまま。

---

## 実装メモ

### スマートフレーミング安定化

- **detectAllPositions**: 検出はサンプリング間隔で行い、サンプル間のフレームは直前の加重中心でホールド。最終的な `detectionInterval` を返し、後続の補間でギャップ閾値に利用。
- **補間（interpolate）**: 欠損区間を短いギャップ（`shortGapFrames = detectionInterval × 2`）と長いギャップで分岐。短いギャップは線形補間、長いギャップは前値から fallback（中央）へ徐々に戻す。開幕は fallback のまま、末尾は ease-out。
- **PersonTracker**: 検出が0でも `maxMissed` 範囲内のトラックを維持し、`weightedCenterAllowingMissed()` によるホールド中心を返す。
- **holdAndFollow**: 起動直後は即時スナップ。フォロー開始時は `warmupFrames = 15` でウォームアップ。フォロー完了時にのみ `settledFrame` をリセット。

### ドラッグ&ドロップ

- NSURL/URL/Data/String を順に扱うフォールバック処理で Finder 等からのドロップ互換性を確保。
- ドラッグ中は常にドロッププロンプトを表示。
- チェックマークは「変換が正常に完了した」ことを示し、ファイル選択直後は中立的なビデオアイコンを表示。

### エンコード

- H.264 / H.265（非VT選択時）は `VTCompressionSession` によるソフトウェアエンコード経路を使用。
- H.264 (VT) / H.265 (VT) は `AVAssetWriter` によるハードウェアエンコード。
- ProRes422 (VT) はハードウェアエンコーダの有無を `VTCopyVideoEncoderList` で事前チェック。
- HDR パススルー時は HEVC Main10 プロファイルを使用。
- HEVC SW エンコーダは B フレーム無効化（`AllowFrameReordering = false`）で QTX/Finder 互換を確保。
- HEVC HDR パススルーはコンポジター出力を 32BGRA（整数）にし、エンコーダの二重 OETF を回避。

### キャンセル処理

- `CancelToken` + `VTSessionRegistry` による安全なリソース解放。
- `videoReadQueue`（直列キュー）で `copyNextSampleBuffer()` を直列化。
- `safeResume` ガードで継続の二重 resume を防止。
- `VerticalVideoCompositor` で保留中リクエストを追跡し、中断時に `finishCancelledRequest()` を呼出。

---

## VideoExportSettings

| 設定 | 選択肢 |
|---|---|
| Resolution | `720p` (720×1280) / `1080p` (1080×1920) |
| FrameRate | `24` / `29.97 DF` / `30` / `60` fps |
| Codec | `H.264` / `H.265` / `H.264 (VT)` / `H.265 (VT)` / `ProRes422 (VT)` |
| Container | `MOV` / `MP4`（HEVC のみ選択可。H.264 は MP4 固定、ProRes は MOV 固定） |
| Bitrate | `8` / `10` / `12` Mbps（ProRes選択時は無効） |
| EncodingMode | `VBR` / `CBR`（フレーム順序固定＋最大1フレームIフレーム） / `ABR`（ProRes選択時は無効） |
| Crop | `Fit W` / `Fit H` / `Square` / `4:3` / `3:4`（スマートフレーミングON時は無効） |

---

## SmartFramingSettings

| 設定 | 説明 |
|---|---|
| enabled | スマートフレーミングON/OFF |
| smoothness | **Fast** (followFactor=0.12) / **Normal** (0.06) / **Slow** (0.03) |

---

## HDR→SDR Settings

| 設定 | 説明 |
|---|---|
| enabled | HDR→SDR変換ON/OFF |
| Tone Map | **Natural** / **Cinematic**（macOS 15+: 両方 CIToneMapHeadroom、macOS 14: Reinhard / ACES フォールバック） |

---

## 注意事項

- スマートフレーミングONの場合、第1パスで全フレームをスキャンするため変換時間が増加する。
- hev1 入力の場合、変換前に hvc1 へのリマックス処理が追加される（再エンコードなし）。
- DNxHD/DNxHR コーデックは macOS 標準ではデコード不可。Avid コーデックパックのインストールが必要。
- サンドボックス有効のため、ユーザーが選択したファイルのみアクセス可能。
- Liquid Glass UI（`.glassEffect()`）は Xcode 26 / macOS 26 以降で利用可能。現在は `.ultraThinMaterial` + グラデーション背景で代替（コード内に `// TODO: Xcode 26+` コメントあり）。

---

## 今後の改善案

- [x] カスタム出力解像度の選択
- [x] フレームレートの選択オプション
- [x] プレビュー機能
- [x] スマートフレーミング（人物追従）
- [x] バッチ処理（複数ファイルの一括変換）
- [x] HDR/HLG対応（HDR→SDR変換）
- [x] AVAssetWriterを使用した厳密なビットレート制御
- [x] VTCompressionSessionによるソフトウェアエンコード経路
- [ ] 透かしやテキストの追加機能
- [ ] 物体検出（人物以外のオブジェクト追従）
- [ ] ファイル保存場所・ファイルネームの明示指定

---

## ライセンス

このプロジェクトは [MIT License + Commons Clause](LICENSE) の下で公開されています。詳細は LICENSE ファイルを参照してください。