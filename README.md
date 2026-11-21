# Strings

Piano と同じ SwiftUI・Rust・AUv3 構成で作ったストリングス音源です。macOS、iPhone、iPad で単体起動でき、対応する DAW では AUv3 として使えます。画面は英語、日本語、简体中文に対応します。

[試聴用 WAV](docs/strings-demo.wav) は、前半が弓弾きのコード、後半がピチカートのアルペジオです。

## ビルド

macOS 15 または iOS・iPadOS 18 以降が対象です。ビルドには Xcode と Rust（rustup）が必要です。

1. `Strings.xcodeproj` を開きます。Mac では **Strings-macOS**、iPhone・iPad では **Strings** スキームを選びます。
2. Apple シリコン Mac の iOS ビルド用には `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` を実行します。Intel Mac では `rustup target add x86_64-apple-darwin x86_64-apple-ios` を実行します。
3. iPhone・iPad の実機では、アプリと AUv3 拡張の両方で **Signing & Capabilities** の開発チームを指定します。

`project.yml` を変更した場合は、XcodeGen の `xcodegen generate` で Xcode プロジェクトを更新できます。

## 演奏

鍵盤の矢印で表示音域を切り替えられます。iPhone と iPad ではマルチタッチで和音を弾けます。手のアイコンで、次に鳴らす音からピチカートに切り替えます。スライダーアイコンから明るさとルームリバーブを調整できます。

音が鳴り続けるときは、鍵盤上の停止ボタン（Mac では Esc キーも可）で発音とリバーブを止め、サステインを解除できます。

単体アプリは接続済みの CoreMIDI 入力を検出します。単体アプリと AUv3 が受け付ける演奏操作は以下のとおりです。

| MIDI | 操作 |
| --- | --- |
| Note On / Off | A0–C8、ベロシティ対応 |
| CC11 | 鳴っている音も含めてエクスプレッションを調整 |
| CC64 | サステインをオン・オフ |
| CC67 | ピチカートをオン・オフ |
| CC120 / CC123 | すべての発音とリバーブを停止し、サステインを解除 |

AUv3 の表示名は **Strings: Bowed Ensemble** です。モノまたはステレオの 44.1–96 kHz 出力と、明るさ・ルームリバーブのパラメータを備えます。Mac ではアプリを起動してから、AUv3 対応 DAW のインストゥルメント一覧で選びます。登録後は `auval -v aumu ST01 LStr` で検証できます。

## 音源

録音素材を使わない加算合成です。弓弾きは、独立した微小なピッチ差・ビブラート・定位を持つ 3 系統を重ねます。ベロシティでアタックと倍音構成が変わります。ピチカートは撥弦位置を反映した倍音分布に切り替え、押鍵中は自然に減衰します。サステインがオフの場合、弓弾きもピチカートも鍵盤を離すと短くフェードします。リバーブの余韻は設定に応じて残ります。最大同時発音数は 32 です。

## ロードマップ

- 🟢 [Done] 弓弾き、ピチカート、明るさ、ルームリバーブ、MIDI エクスプレッション
- 🟢 [Done] macOS・iOS・iPadOS アプリ、AUv3、3 言語の画面表示
- 🟠 [Next] スピッカートとレガート用の発音制御
- ⭕️ [Pending] 実機での発音レイテンシー、外部 MIDI 機器と DAW での試奏
