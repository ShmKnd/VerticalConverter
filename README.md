# Vertical Converter

16:9の横長動画をYouTubeショート用の縦型動画（9:16）に変換するmacOSアプリです。

## 機能

- **ドラッグ&ドロップ対応**: 動画ファイルをウィンドウにドラッグするだけで簡単に選択
- **背景生成**: 縦型にした際に空く上下の部分には、元動画を拡大してブラーをかけた背景を自動生成
- **高品質エンコード**: H.265（HEVC）+ AACコーデックで高品質な動画を出力
- **カスタマイズ可能なビットレート**: 8, 10, 12 Mbpsから選択可能
- **SwiftUIによる直感的なUI**: モダンで使いやすいインターフェース

## 技術仕様

- **対応OS**: macOS 14.0以降
- **フレームワーク**:
  - SwiftUI（UI）
  - AVFoundation（動画処理）
  - VideoToolbox（ハードウェアアクセラレーション）
  - Core Image（ブラー処理）
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
4. 「変換開始」ボタンをクリック
5. 変換完了後、自動的にFinderで保存先が表示されます

## プロジェクト構造

```
VerticalConverter/
├── VerticalConverter.xcodeproj/    # Xcodeプロジェクトファイル
├── VerticalConverter/
│   ├── VerticalConverterApp.swift  # アプリのエントリーポイント
│   ├── ContentView.swift            # メインUI（ドラッグ&ドロップ、設定）
│   ├── VideoProcessor.swift         # 動画変換のメインロジック
│   ├── VerticalVideoCompositor.swift # カスタム動画合成（背景生成）
│   ├── Assets.xcassets/             # アプリアイコンとアセット
│   └── VerticalConverter.entitlements # アプリの権限設定
└── README.md
```

## 主要コンポーネント

### ContentView.swift
SwiftUIで実装されたメインUI。ドラッグ&ドロップ、ファイル選択、ビットレート設定、プログレス表示を担当。

### VideoProcessor.swift
AVFoundationを使用した動画処理のメインロジック。入力動画の解析、コンポジションの作成、エクスポート処理を実行。

### VerticalVideoCompositor.swift
AVVideoCompositingプロトコルを実装したカスタムコンポジター。各フレームに対してブラー背景を生成し、元動画を中央に配置。

## 処理の流れ

1. 入力動画の読み込みとトラック解析
2. 9:16の出力サイズでAVMutableCompositionを作成
3. カスタムビデオコンポジターで各フレームを処理：
   - 元動画を拡大してブラーをかけた背景を生成
   - 元動画を適切にスケーリングして中央に配置
   - 背景と元動画を合成
4. H.265 + AACでMP4形式にエクスポート

## 注意事項

- **ビットレート設定**: 現在の実装では、AVAssetExportSessionを使用しているため、プリセット名でビットレートが決定されます。厳密なビットレート制御が必要な場合は、AVAssetWriterへの移行が必要です。
- **サンドボックス**: アプリはApp Sandboxを有効にしています。ユーザーが選択したファイルのみにアクセス可能です。
- **処理時間**: 動画の長さと品質によって、変換には数分かかる場合があります。

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
