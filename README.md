# Vertical Converter

16:9の横長動画をYouTubeショート/リール用の縦型動画（9:16）に変換するmacOSアプリです。

---

## 機能

| 機能 | 説明 |
|---|---|
| ドラッグ&ドロップ | 動画ファイルをウィンドウにドロップするだけで選択 |
| ブラー背景生成 | 上下の余白部分に元動画を拡大ブラーした背景を自動生成 |
| **スマートフレーミング** | Visionで人物を事前解析し、被写体を追従しながら縦クロップ |
| **IOUトラッキング** | 複数人物を個别追跡し、主役（長時間・安定）を自動推定 |
| **Y方向ヘッドルーム制御** | 上半身・ダンス等でも頭の余白を自動確保 |
| 解像度選択 | 720p / 1080p |
| フレームレート選択 | 24 / 29.97 DF / 30 / 60 fps |
| エンコードモード | VBR / CBR / ABR |
| ビットレート選択 | 任意 Mbps |
| キャンセル | 変換中断ボタン |
| Dockプログレス | Dockアイコンにプログレスバー表示 |

---

## 技術仕様

- **対応OS**: macOS 14.0以降
- **言語**: Swift / SwiftUI
- **フレームワーク**: AVFoundation, Vision, Core Image, VideoToolbox
- **出力形式**: MP4（H.265 HEVC + AAC）
- **処理方式**: 2パス（解析→変換）

---

## ビルド方法

```bash
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

固定sigma=20フレームを廃止。FPSに比例して平滑化半径を最適化：

```
sigma = fps × 0.4
// 24fps → 9.6f  ≈ 0.4秒
// 30fps → 12.0f ≈ 0.4秒
// 60fps → 24.0f ≈ 0.4秒
```

ダンス・スポーツ等で遅延感が出ない。

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

## ライセンス

このプロジェクトは教育目的で作成されています。

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
