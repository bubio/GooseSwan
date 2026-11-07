# 2026-11-07 — M2仕上げ＋タイミング基盤（WSHWTest全合格、WSTimingTest着手）

## テスト資産の追加
- nasm 2.16.03を用意（aptのリストが使えず、Debianの .deb を `~/workspace/tools/nasm/root/usr/bin/nasm` に展開）。
- WSTimingTest（main、V0.4.0）とWSHWTest（main、V0.2.2）をソースからビルドし、`tests/roms/` にROMとソースを格納。

## 起動の修正：線形ウィンドウはトップアライン
- WSHWTest.wsc は 768 KB で、アドレス空間 0x40000–0xFFFFF に対応するイメージ（`.text start=0x40000`、`.data start=0xF0000`）。従来の `% rom.len` デコードではリセットフェッチ（0xFFFF0）がファイル中央のゼロ領域に落ちて起動しなかった。
- 線形ウィンドウを「ROM末尾がアドレス空間末尾に合う」トップアラインに変更：`((bk_linear << 20) + (p & 0xFFFFF) + rom.len - 0x100000) % rom.len`。2の冪サイズ（〜1MB）では従来と一致し、WSCpuTestにも影響なし。

## サイクル／スキャンライン基盤（WSモード）
- フレーム実行をステップ数（100k/frame）からサイクル予算（159ライン×256＝40,704サイクル/frame）に変更。命令ごとの見積りは `est_cycles()`（`cyc_tab`＋F6/F7・FFはModRM regで分岐、REP文字列はCX消費で倍率）。
- ポート0x02（LCD_LINE）は現在ラインを返す。割り込み原因（INT_CAUSE）は「有効なソースだけがラッチする」方式に変更（Swaniumの注記どおり。WSHWTestが検証する仕様）。VBLANK_STARTはライン144到達時に発生。
- HBL/VBLタイマ（0xA2–0xAB）：周期ポートへの書き込みはカウンタもリセット、カウンタは読み取り専用、HBLには「無効でもカウンタ=1かつIRQ有効なら発火する」ラッチクセ（Swanium由来）も実装。
- キー押下エッジでKEY_PRESS原因をラッチ。HLT中のキー待ちにはランナーがAタップで自動応答（freeze 200フレーム＋halted時）。フレーム上限は60,000→2,000,000（サイクル実行ではTest Allに約58万フレーム要るため）。メニュー引数 `m1`〜`m9`（汎用）と最終状態ダンプを追加。

## I/Oレジスタモデル（WSHWTestの表を転記）
- SPHINXのモノ／カラー別マスク表（`ioRegMasksSPHINXMono`/`ioRegMasksSPHINX`、184ポート分）を読み取りマスク＋常時セットビットとして実装。モードはSYSTEM_CTRL2（0x60）のVMODE_COLORビットで切替。
- 注意：表の `0xFFFF` は「テストスキップ」＝恒等（マスクなし）。当初「常時セット=0xFF」と符号化したため、SYSTEM_CTRL2の read-modify-write が汚染されカラーモード誤判定＋タイマカウンタ読みが壊れた。
- 特殊レジスタ：SYSTEM_CTRL1はスティッキー（0x87保持／0x0Cのみ書換可、初期値0x02）、SND_OUT_CTRLは下位4ビットのみ、INT_VECTORは0xF8マスク（配送時も）、SERIAL_DATA読みは0、KEYPADセレクトは0x70マスク。

## ノイズLFSR（APUの最初の部品）
- 15ビットXNORフィードバック `1 ^ bit7 ^ bit_tap`、タップはモード0–7で 14/10/13/4/8/6/9/11。周期は `2048 − pitch4` CPUサイクル、ゲートは NOISE_ENABLE（0x8E bit4）＋ ch4オン＋ノイズモード（0x90）。リセットビットは自己クリア。読みはポート0x92/0x93。
- WSHWTestのノイズテスト（モード0は32,767ステップをソフトウェアLFSRと逐一照合）に全モード合格。

## 結果
- **WSHWTest Test All 全合格**（testIrq、HBL/VBLタイマ7件、IO Regsのモノ＋カラー両パス、Noise 8モード）。60,000フレームの走行で "Failed" 0件、Test All 7周を確認。
- WSTimingTest：測定法を解読（HBLタイマで1000回ループの経過ライン数を測り、期待値と完全一致で合否）。ページ1（17件）は見積りv2で **16/17合格**（Base loop＝NOP×3＋IN＋DEC＋JNZ＝14サイクルに fit：NOP=1、IN DX=5、Jcc=5、PUSH/POP=1等）。唯一の不合格 "Unaligned" はプリフェッチのアライン効果（+4ライン）で未モデル。
- 回帰：8086コーパス 634,406/646,000、V20コーパス 2,980,747/3,125,000（いずれも従来ベースラインと一致）。WSCpuTestは全7スイートを個別に再検証し、いずれも失敗0（logic 74.5M命令／arith 632M／rot 122.7M／misc 230.6M／mul 9.17G／div 17.15G／sdiv 16.68G命令）。サイクル実行では各スイートに数分〜12分かかる（命令スループット自体は約24M/sで従来並みだが、フレーム駆動のキー操作やアイドルで実行命令数が膨らむ）。

## 次の一手
- WSTimingTestの残りページ（X右キーでページ送りするランナースクリプト＋フォーム別コスト（メモリ形の割増）＋プリフェッチ・アラインのモデル化）。
- M3の描画側（フレームバッファ生成とハッシュ比較）は未着手。カートリッジ／内蔵EEPROMも未実装（現テスト資産では未検証）。
