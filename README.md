# Vertical Converter

16:9の横長動画をYouTubeショート/リール用の縦型動画（9:16）に変換するmacOSアプリです。

---

## 機能

| 機能 | 説明 |
|---|---|
| ドラッグ&ドロップ | 動画ファイルをウィンドウにドロップするだけで選択 |
| **スマートフレーミング** | Visionで人物を事前解析し、被写体を追従しながら縦クロップ |
| **IOUトラッキング** | 複数人物を個别追跡し、主役（長時間・安定）を自動推定 |
| **Y方向ヘッドルーム制御** | 上半身・ダンス等でも頭の余白を自動確保 |
| フレームレート選択 | 24 / 29.97 DF / 30 / 60 fps |
| ビットレート選択 | 任意 Mbps |
| キャンセル | 変換中断ボタン |
| Dockプログレス | Dockアイコンにプログレスバー表示 |
---

## 技術仕様

- **対応OS**: macOS 14.0以降
- **言語**: Swift / SwiftUI
- **フレームワーク**: AVFoundation, Vision, Core Image, VideoToolbox
- **処理方式**: 2パス（解析→変換）

---

## ビルド方法
cd VerticalConverter
open VerticalConverter.xcodeproj
# Xcode で ⌘+B または ⌘+R
```

---

## 使用方法

1. 動画ファイルをウィンドウにドラッグ、またはクリックして選択
2. 設定パネルで解像度・FPS・ビットレート・エンコードモードを選択
3. スマートフレーミングパネルでON/OFF・追従速度を設定
4. 「変換開始」ボタンをクリック
5. 変換完了後、Finderで保存先が自動表示される

---

## プロジェクト構造

```
VerticalConverter/
├── VerticalConverterApp.swift              # エントリーポイント
├── ContentView.swift                       # メインUI + ContentViewModel
├── VideoProcessor.swift                    # 変換オーケストレーション（2パス）
├── VideoExportSettings.swift               # エクスポート設定（解像度・FPS・モード）
├── SmartFramingSettings.swift              # スマートフレーミング設定
├── SmartFramingAnalyzer.swift              # 第1パス: Vision解析 + IOUトラッキング
├── VerticalVideoCompositor.swift           # 第2パス: カスタムフレーム合成
├── CustomVideoCompositionInstruction.swift # AVVideoCompositionInstruction実装
└── DockProgress.swift                      # Dockプログレスバー
```

---

## アーキテクチャ

### 処理フロー（2パス）

```
[第1パス: SmartFramingAnalyzer]
  入力動画を全フレームスキャン
    → 人物検出（VNDetectHumanBodyPoseRequest + VNDetectFaceRectanglesRequest）
    → IOUトラッキング（PersonTracker）
    → 主役スコア計算
    → X/Y 正規化座標を記録
    → 線形補間（検出間フレームを補完）
    → 双方向ガウシアンスムージング（fps依存 sigma）
    → ホールド＆フォロー（X: 3秒ホールド / Y: 0.5秒ホールド）
    → precomputedOffsets: [CGPoint] を出力

[第2パス: VerticalVideoCompositor]
  フレームごとに precomputedOffsets[i] を参照
    → scale × (offsetX, offsetY) を適用してクロップ
    → スマートフレーミングOFFの場合はレターボックス+ブラー背景
```

---

## スマートフレーミング詳細

### ① fps依存ガウシアン sigma

平滑化強度を少し弱めて過度な前後ブレを抑制するように変更しました（開発セッションでの調整）：

```
sigma = fps × 0.2
// 24fps → 4.8f  ≈ 0.2秒
// 30fps → 6.0f  ≈ 0.2秒
// 60fps → 12.0f ≈ 0.2秒
```

強い平滑（以前の 0.4 秒相当）は、人物の消失区間の前後に影響が波及しやすかったため、安定化のために弱めています。

---

### ② IOUトラッキング + 主役推定

**旧実装の問題点**  
`(minX + maxX) / 2` では主役と通過者を区別できない。

**新アーキテクチャ**

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

## 実装メモ（本セッションでの主要な修正点）

以下は開発中の安定化対応で加えた実装上の変更点です（ユーザー向けUIには直接表示されませんが、挙動に影響します）。

- detectAllPositions
   - 検出はサンプリング間隔（検出間隔）で行い、サンプル間のフレームは直前の加重中心でホールドします。これにより、検出の欠落区間で不自然な直線補間が発生するのを防ぎます。
   - 最終的な `detectionInterval` を返すようになり、後続の補間でギャップ閾値に利用します。

- 補間（interpolate）
   - 欠損区間を短いギャップ（`shortGapFrames`）と長いギャップで扱いを分けます。
      - 短いギャップ: 前後を線形補間
      - 長いギャップ: 前値から `fallback`（中央）へ徐々に戻す
   - `shortGapFrames` は `detectionInterval * 2` を基準に自動設定されます。
   - 開幕（leading）は `fallback` のまま（`holdAndFollow` の初期化で最初の検出位置に即時スナップするため）。末尾（trailing）は ease-out で戻ります。

- PersonTracker
   - 検出が0でも `maxMissed` 範囲内のトラックがある場合はトラックを維持し、その間は `weightedCenterAllowingMissed()` によるホールド中心を返すようにしました（短時間のロストでカメラが揺らぎにくくなります）。

- holdAndFollow（ホールド＆フォロー）
   - 起動直後は最初の有効フレームで `cameraOffset` を即時スナップして開幕の大きなジャンプを防止します。
   - フォロー開始時は `followFactor` を 0 から線形に増やすウォームアップ（デフォルト `warmupFrames = 15`）を導入し、ホールド中に溜まった大きなズレが一気に適用されるのを防ぎます。
   - フォロー完了時にのみ `settledFrame` をリセットしてホールドタイマーをスタートするように変更し、完了直後の再トリガーを抑制します。

これらの調整により、開幕や被写体不在時の「大きなジャンプ」や、ホールド→フォロー→ホールドの繰り返しによるカクつきが大幅に改善されています。

## 本セッションでのユーザー向け変更 (2026-02-26)

以下は、この開発セッションで UI/挙動として影響のある変更点です。ユーザーの操作感に関する重要な修正を含みます。

- ドラッグ&ドロップの互換性向上: ドロップ時に受け取るデータの型が環境によって異なるため、NSURL/URL/Data/String を順に扱うように処理を強化しました。Finder などからのドロップ互換性が改善されています。
- ドロップ時のフィードバック改善: ドラッグ中は常に「ドロッププロンプト（大きなビデオアイコン）」を表示するように変更しました。既にファイルが選択されている状態でも、ホバー時のフィードバックが明確になります。
- チェックマーク表示の意味の変更: これまではファイルを選択しただけでチェックマークが表示されることがあり、ユーザーに誤解を与えていました。チェックマークは「変換が正常に完了した」ことを示すように変更し、ファイル選択直後は中立的なビデオアイコンを表示します。これにより「未変換なのに完了しているように見える」問題を解消しています。
- デバッグログ（開発用）: Debug ビルド時にドロップ時の型（registeredTypeIdentifiers）や選択された URL の更新をログ出力するように追加しました。トラブルシューティング用であり、リリースビルドでは出力されません。
- 内部フラグ追加: `ContentViewModel` に `hasConverted` フラグを導入し、ファイル選択/ドロップ時にリセット、変換成功時にセットすることで上記のチェックマーク挙動を制御しています。

影響: ユーザーがファイルをウィンドウにドロップした直後はチェックマークは表示されず、変換が完了するとチェックマークに変化します。ドラッグ中のホバーで表示が変わるため、ドロップ操作の視覚的な確信が得られるはずです。

- エンコード挙動の注記: UI で `H.264 (VT)` / `H.265 (VT)` のような VT バリアントを選べますが、現在の実装では AVAssetWriter を用いる共通の書き出し経路を使っており、選択が即座に「別実装（ソフト/ハード）に分岐」するわけではありません。例外的に `ProRes422 (VT)` はハードウェアエンコーダの有無をチェックして利用可否を制御しています。
- クラッシュ修正: 開発中に「非VT を選んだ際にソフトウェア（CPU）経路を優先するために `AVVideoEncoderSpecificationKey` を圧縮プロパティへ注入する」試みを行いましたが、H.264（avc1）など一部のコーデックではこのキーがサポートされず、`AVAssetWriterInput` 初期化時に例外を発生させる原因となったため、この注入は撤回して安全な設定に戻しました。現在はクラッシュは解消されています。
- 今後の改善案（エンコード）: 真にソフトウェア（CPU）経路を確実に使う必要がある場合は、`VTCompressionSession` を直接使った専用のエンコードパスを実装する必要があります。これは本セッションでは未実装で、将来のタスクとして検討中です。

---

## VideoExportSettings

| 設定 | 選択肢 |
|---|---|
| Resolution | `720p` (720×1280) / `1080p` (1080×1920) |
| FrameRate | `24` / `29.97 DF` / `30` / `60` fps |
| EncodingMode | `VBR` / `CBR`（フレーム順序固定＋最大1フレームIフレーム） / `ABR` |
| Bitrate | 任意 Mbps |

---

## SmartFramingSettings

| 設定 | 説明 |
|---|---|
| enabled | スマートフレーミングON/OFF |
| smoothness | **Fast** (followFactor=0.12) / **Normal** (0.06) / **Slow** (0.03) |

---

## 注意事項

- スマートフレーミングONの場合、第1パスで全フレームをスキャンするため変換時間が増加する。
- サンドボックス有効のため、ユーザーが選択したファイルのみアクセス可能。
- Liquid Glass UI（`.glassEffect()`）は Xcode 26 / macOS 26 以降で利用可能。現在は `.ultraThinMaterial` + グラデーション背景で代替（コード内に `// TODO: Xcode 26+` コメントあり）。

---

## ライセンス

このプロジェクトは教育・研究目的で作成されています。


## 機能

- **ドラッグ&ドロップ対応**: 動画ファイルをウィンドウにドラッグするだけで簡単に選択
- **背景生成**: 縦型にした際に空く上下の部分には、元動画を拡大してブラーをかけた背景を自動生成
- **🔥 スマートフレーミング（NEW！）**: Vision フレームワークで人物を自動検出し、被写体を追従
  - 人体のポーズ検出と顔検出を組み合わせて最適な構図を実現
  - スムーズな追従（Fast/Normal/Slowから選択可能）
  - 人物が検出されない場合は自動的に中央配置
- **高品質エンコード**: H.265（HEVC）+ AACコーデックで高品質な動画を出力
- **カスタマイズ可能なビットレート**: 8, 10, 12 Mbpsから選択可能
- **SwiftUIによる直観的なUI**: モダンで使いやすいインターフェース

## 技術仕様

- **対応OS**: macOS 14.0以降
- **フレームワーク**:
  - SwiftUI（UI）
  - AVFoundation（動画処理）
  - VideoToolbox（ハードウェアアクセラレーション）
  - Core Image（ブラー処理）
  - **Vision（人物検出とスマートフレーミング）**
- **出力形式**: MP4（H.265 + AAC）
- **出力解像度**: 1080 x 1920（9:16）

## ビルド方法

1. Xcodeでプロジェクトを開く：
```bash
cd VerticalConverter
open VerticalConverter.xcodeproj
```

2. Xcodeでビルド（⌘ + B）または実行（⌘ + R）

## 使用方法

1. アプリを起動
2. 動画ファイルを以下のいずれかの方法で選択：
   - ウィンドウに直接ドラッグ&ドロップ
   - 「ファイルを選択」ボタンをクリック
3. ビットレートを選択（8, 10, 12 Mbpsから選択）
4. **スマートフレーミング（オプション）**:
   - トグルをONにすると人物を自動検出・追従
   - 追従速度を選択（Fast/Normal/Slow）
5. 「変換開始」ボタンをクリック
6. 変換完了後、自動的にFinderで保存先が表示されます

## プロジェクト構造

```
VerticalConverter/
├── VerticalConverter.xcodeproj/    # Xcodeプロジェクトファイル
├── VerticalConverter/
│   ├── VerticalConverterApp.swift       # アプリのエントリーポイント
│   ├── ContentView.swift                # メインUI（ドラッグ&ドロップ、設定）
│   ├── VideoProcessor.swift             # 動画変換のメインロジック
│   ├── VerticalVideoCompositor.swift    # カスタム動画合成（背景生成+スマートフレーミング）
│   ├── SmartFramingSettings.swift       # スマートフレーミング設定
│   ├── Assets.xcassets/                 # アプリアイコンとアセット
│   └── VerticalConverter.entitlements   # アプリの権限設定
└── README.md
```

## 主要コンポーネント

### ContentView.swift
SwiftUIで実装されたメインUI。ドラッグ&ドロップ、ファイル選択、ビットレート設定、スマートフレーミング設定、プログレス表示を担当。

### VideoProcessor.swift
AVFoundationを使用した動画処理のメインロジック。入力動画の解析、コンポジションの作成、エクスポート処理を実行。

### VerticalVideoCompositor.swift
AVVideoCompositingプロトコルを実装したカスタムコンポジター。各フレームに対してブラー背景を生成し、元動画を配置。
- **Vision フレームワークで人物検出**: 人体のポーズ検出（VNDetectHumanBodyPoseRequest）と顔検出を組み合わせ
- **スマートフレーミング**: 検出された人物の位置に基づいて、動画のY座標オフセットを動的に調整
- **スムーズな追従**: dampingFactorによるイージング処理で自然な動きを実現

### SmartFramingSettings.swift
スマートフレーミングの設定を定義する構造体。追従速度（Fast/Normal/Slow）とdampingFactorの設定。

## 処理の流れ

1. 入力動画の読み込みとトラック解析
2. 9:16の出力サイズでAVMutableCompositionを作成
3. カスタムビデオコンポジターで各フレームを処理：
   - **（オプション）Vision で人物を検出し、最適な配置を計算**
   - 元動画を拡大してブラーをかけた背景を生成
   - 元動画を適切にスケーリングして配置（スマートフレーミング適用時は人物中心）
   - 背景と元動画を合成
4. H.265 + AACでMP4形式にエクスポート

## スマートフレーミングの仕組み

1. **人物検出**: 各フレームでVisionフレームワークを使用
   - 第一優先: 人体のポーズ検出（首、肩などの関節点から上半身の中心を推定）
   - フォールバック: 顔検出
2. **位置計算**: 検出された人物を画面の上から1/3の位置に配置
3. **スムーズな追従**: dampingFactorでイージング処理を適用し、滑らかな動きを実現
4. **エッジケース処理**: 
   - 人物が検出されない場合は中央配置に戻る
   - 動画が画面外に出ないように制限

## 注意事項

- **ビットレート設定**: 現在の実装では、AVAssetExportSessionを使用しているため、プリセット名でビットレートが決定されます。厳密なビットレート制御が必要な場合は、AVAssetWriterへの移行が必要です。
- **サンドボックス**: アプリはApp Sandboxを有効にしています。ユーザーが選択したファイルのみにアクセス可能です。
- **処理時間**: 動画の長さと品質によって、変換には数分かかる場合があります。スマートフレーミングを有効にすると、人物検出の処理が追加されるため、若干時間が長くなります。

## キャンセル処理とリソース解放の改善（開発ログ 2026-02-26）

開発セッションで「中止（Cancel）ボタンを押しても変換が止まらない／リソースが解放されない」問題を重点的に修正しました。主な変更点は以下の通りです。

- **問題点**: AVAssetReader/Writer や VideoToolbox のセッションが中断時に競合・リークし、Swift の継続（continuation）二重 resume や VideoToolbox の refcon 二重解放が発生していた。
- **VideoProcessor.swift の修正**:
   - `CancelToken` を導入し、ループ／append／エンコード処理で常に取消状態を検査。
   - `VTSessionRegistry` を追加し、VTCompressionSession と関連 refcon を一元管理して中断時に安全に無効化・解放。
   - `videoReadQueue`（直列キュー）で `copyNextSampleBuffer()` を直列化し、リーダーの競合を回避。
   - 継続呼び出しの `safeResume` ガードを追加して「二重 resume」によるクラッシュを防止。
   - `AVAssetWriterInput.append(_:)` の失敗時に取消トークンを優先して `cancelled` と判定するよう調整。
   - onCancel の実行順を見直し（取消トークン設定 → VT セッション無効化 → 少し待機 → 入力終了通知 → reader/writer の cancel）、出力ファイルの削除を writer の状態安定化まで遅延。
- **VerticalVideoCompositor.swift の修正**:
   - 保留中の `AVAsynchronousVideoCompositionRequest` を追跡し、中断時に `finishCancelledRequest()` を呼ぶようにしてコンポジッター側のリソースを解放。

これらの変更により、Swift の致命的な継続エラーは解消され、キャンセル操作でリソースがより確実に解放されるようになっています。引き続きユーザー側で H.264/H.265（VT/非VT）それぞれの手動テストをお願いしています。

詳細やログが必要であれば、実行時ログ（NSLog）や再現手順を教えてください。

## 今後の改善案

- [ ] AVAssetWriterを使用した厳密なビットレート制御
- [ ] バッチ処理（複数ファイルの一括変換）
- [ ] カスタム出力解像度の選択
- [ ] フレームレートの選択オプション
- [ ] プレビュー機能
- [ ] ブラーの強度調整
- [ ] 透かしやテキストの追加機能
- [x] ✅ **スマートフレーミング（人物追従）** - 実装完了！
- [ ] 物体検出（人物以外のオブジェクト追従）
- [ ] 手動でのフレーミング調整（ドラッグで位置変更）
