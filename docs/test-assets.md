# GooseでWonderSwanエミュ — テスト資産と進め方のメモ

作成: 2026-11-07。状態: 構想段階（着手は未決定）。
きっかけ: 言語名 Goose にかけて白鳥＝WonderSwan。GBエミュ（Node／Goose移植）で成立した「テストが先に固定され、実装→実行→合否を回す」TDD式の進め方が、WSでも可能かを調べた結果。

参考実装の本命は自分の **Swanium**（github.com/bubio/Swanium、Rust）。`crates/core` に cpu / ppu / apu / bus が分かれて入っており UI（Slint）と分離されている。この構成をそのまま Goose 版の雛形にでき、V30MZの挙動で迷ったときの仕様代わりにもなる。

## テスト資産

### 1. CPU単体テスト（JSONコーパス）— TDDの主軸
1命令ごとに「初期状態（レジスタ＋メモリ）→ 実行 → 最終状態」を記録したケース集。ハーネスに読ませれば命令単位で pass/fail が返るので、GBのシリアル方式と同じくらい綺麗な反復が成立する。

- **SingleStepTests/8086**: 実機（8086）から採取したハードウェア検証済みケース。命令網羅の土台。
- **SingleStepTests の NEC V20 スイート**: 同じ形式でV20用もある。V30MZに一段近い。
- **nuV30（wickerwaka/nuV30）**: V30実チップから採取し、SingleStepTests形式で出したサンプル（26命令フォーム×500ケース、`tests/v30`）。範囲は部分的だが、V30そのもののデータとしては一番正確。
- 進め方: 8086で共通部 → V20/V30で差分 → 下記 WSCpuTest で MZ 固有の差異を潰す、の順。
- Goose 側: 標準ライブラリに json があるので取り込みは可能。ケース数は万単位になるため、遅ければ Node/Python の変換ツールで自前バイナリ形式に落とす逃げ道を用意する。

### 2. テストROM（実機検証系）
- **WSCpuTest**（FluBBaOfWard）: NEC V30MZ の命令挙動そのものを見る。8086/V30スイートとの差分＝MZ固有挙動の洗い出し用。
- **WSTimingTest**（FluBBaOfWard）: V30MZの命令タイミング。
- **WSHWTest**（FluBBaOfWard）: SoC側（割り込み、PPUタイマ等）のハードウェアテスト一式。
- **ws-test-suite**（asiekierka、MIT）: 「WonderSwan emulator test suite」と銘打った小テスト集。Wonderful toolchain の人。
- その他（awesome-wsdev の Accuracy test ROMs 欄）: rtctest（2003マッパー＋RTC）、KarnakTest（PCv2 KARNAKマッパー）、Robert Peip のスプライト優先度／ウィンドウ用テストROM、144p Test Suite for WS。

注意点: GBの Blargg と違い、WSのテストROMは結果を**画面で見せる**型が基本。自動判定にはハーネス側の工夫が要る（下記）。

### 3. 精度リファレンス（テストではないが物差しになるもの）
- ares（WonderSwanコアの精度に定評）、Mednafen、NitroSwan（FluBBaOfWard、DSi向け。テストROMの作者本人のエミュ）。
- ドキュメント: WSdev Wiki（ws.nesdev.org）が現行の一次情報源。WSTech 2.4 は古く誤りを含むので鵜呑みにしない。

## ハーネスの設計（GB版との対比）

| 対象 | GB版 | WS版 |
|---|---|---|
| CPU | Blargg ROM＋シリアル文字出力 | SingleStepTests JSON を直接実行（ROM不要） |
| SoC／PPU | （未着手） | テストROMを N フレーム実行 → フレームバッファを PPM ダンプ → 期待画像とハッシュ比較 |
| 起動 | 固定エントリ | カートリッジ末尾のフッターからエントリ決定。内蔵ブートROMなしで直接起動するのがエミュの通例（Swanium の起動処理を参照） |

期待画像の入手先（実機キャプチャ or 定評エミュの出力）が SoC 系自動判定の前提。最初は目視確認から始めて、固まったものからハッシュ化する。

## 進め方（段階）

1. **足場**: Goose で SingleStepTests ハーネス＋V30MZコアの最小命令（MOV／ALU中心）。進捗はケースの pass 数で測る。
2. **CPUの完成度上げ**: 8086全命令 → 文字列命令・乗除算・割り込み → V30拡張は WSCpuTest と突き合わせ。
3. **バス／カート**: メモリマップ、I/Oポートでのバンク切り替え、SRAM／EEPROM。
4. **PPU**: 224×144描画。WSHWTest＋フレーム比較。
5. **APU／タイマ／割り込み／DMA**、実ゲームの起動確認。
6. **フロントエンド**: Goose の gfx パッケージ（SDL3 同梱、audio もあり）で画面・音・入力。

規模感: V30MZは16ビット＋セグメント計算＋命令数が LR35902 の数倍。GB編（数時間で12本パス）とは違い、段階を切って進める前提のプロジェクト。

## 未確認・要調査

- FluBBa の3テストROMにビルド済み .ws バイナリがあるか（無ければ Wonderful toolchain 等でのビルド手順から）。
- ws-test-suite の結果出力方式（画面のみか、メモリ等に機械可読な手がかりがあるか）。
- SingleStepTests V20 と V30MZ の差分の範囲（未定義フラグ、文字列命令の挙動など）。
- Goose の json パース速度が万単位ケースに耐えるか。
- カートリッジフッター仕様の正確な定義（WSdev Wiki で確認）。
