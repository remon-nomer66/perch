# Bose(BMAP)対応 設計計画

Perch を Sony(Tandem)専用から、Bose(BMAP)にも対応させるための調査結果と設計方針。
先行実装 3 件(いずれも MIT)の精読に基づく。実装前の一次資料兼ロードマップ。

- 作業ブランチ: `feature/bose-support`(Bose 統合ブランチ)。機能ごとに `bose/<機能>` の支流を切って統合する。
- 参照実装(このリポジトリには含めない。クレジットのみ):
  - **bosectl**(aaronsb, MIT) — Python/Rust/C++。BMAP の最も網羅的な解析、実機キャプチャ、14 機種カタログ。
  - **bozo-bar**(NerdySouth/Tristen, MIT) — Swift/macOS。BLE と RFCOMM 両トランスポートの実装見本。
  - **Bose_QC35_Android**(DavidVentura, MIT) — Kotlin。QC35 の生バイト定義と ACK ワイルドカード方式。

> **重要**: 以下のプロトコル知識(バイト列・UUID・アドレス)は事実データであり参照に制約はないが、
> パーサ/ビルダのコード構造を写経する場合は各 MIT の帰属表示を `THIRD_PARTY_NOTICES.md` に残すこと。

---

## 1. 結論(先に要点)

1. **BMAP は Sony Tandem とは全くの別プロトコル**。フレーム形式・信頼性モデルが異なり、`TandemCore` のコーデックは流用不可。**`BoseCore` を新規に作る**。
2. **BMAP は単一系譜の一枚岩**。QC35(旧)も QC Ultra 2(新)も同じフレーム構造・同じ operator コード。違いは「露出する機能ブロックの広さ」と「RFCOMM チャンネル番号」だけ。機種差は**コード分岐でなくデータ(config)差**で表現するのが先行実装の総意。
3. **トランスポートは機種(世代)で分かれる**:
   - QC35 / QC35 II / NC700 / QC Ultra 2 世代 → **RFCOMM(SPP)**。チャンネルは QC35 系=8、Ultra2 系=2。
   - QC Ultra 初代など一部 → **BLE/GATT**(サービス `0xFEBE`)。
   - よって `BoseSession` は **RFCOMM と BLE の両トランスポート**を持ち、実応答で選ぶ。
4. **Perch の既存資産が土台として優れている**:
   - RFCOMM 下回り(`RFCOMMChannelHost`: 専用スレッド・macOS 26 のコールバック欠落対策・スレッドリーク対策)は Tandem 非依存で、SDP 探索を差し替えるだけで Bose に流用できる。
   - actor ベースのセッション状態機械・`AdjustmentGuard`(set→実報告で確認)・「制御セッション 1 本」ロックは BMAP にもそのまま効く。
   - 先行実装(bozo-bar/bosectl)は `DispatchQueue`+Combine で堅牢性は Perch のほうが上。**プロトコル知識だけ取り、構造は Perch 流に載せる**。
5. **認証は不要**。Bose は `SET`/`START` をクラウド ECDH 認証でロックしたが、`SETGET`(op2) と一部 `START` を主要ブロックで開けたまま。GET(読み)+SETGET(書き)で全ユーザー設定を無認証制御できる。認証本体(Block 18)は移植対象外。

---

## 2. BMAP プロトコル仕様(実装に必要な事実)

### 2.1 フレーム形式

```
Byte 0 : fblock   Function Block ID (1=Settings, 2=Status, 5=AudioMgmt, 7=Control, 31=AudioModes …)
Byte 1 : func     ブロック内の Function ID
Byte 2 : flags    (device_id << 6) | (port << 4) | (operator & 0x0F)   ※device/port は通常 0
Byte 3 : length   payload 長(1 バイト, 最大 255)
Byte 4+: payload
```

- **センチネル無し・エスケープ無し・チェックサム無し・ACK 無し・シーケンス無し**。Tandem より単純。
- 信頼性は RFCOMM/BLE のストリームに依存。エラーは `ERROR`(op4) の payload[0](エラーコード)で判別。
- 連結フレーム: 機器は複数パケットを背中合わせで返す(GetAll 等)。各パケットの length で分割する。

### 2.2 operator(flags 下位 4bit)

| Code | Name | 方向 | 認証 |
|---|---|---|---|
| 0 | SET | 要求 | **要(クラウド ECDH)** — 使わない |
| 1 | GET | 要求 | 不要 |
| 2 | SETGET | 要求(書+読返し) | **主要ブロックで不要** — 書き込みはこれ |
| 3 | STATUS | 応答 | — |
| 4 | ERROR | 応答 | payload[0]=code |
| 5 | START | 要求(アクション) | ブロックにより不要 |
| 6 | RESULT | 応答 | — |
| 7 | PROCESSING | 応答(非同期中) | — |

エラーコード: `1=Length, 3=FblockNotSupp, 4=FuncNotSupp, 5=OpNotSupp(認証), 6=InvalidData, 8=Runtime, 10=InvalidState, 15=InvalidTransition, 20=InsecureTransport`。

### 2.3 主要な機能アドレスと生バイト(実機キャプチャ由来)

読み取り(GET `[fblock, func, 0x01, 0x00]`):

| 機能 | addr | 応答 payload の読み方 |
|---|---|---|
| バッテリ | [2.2] | Ultra=4B 群 `[pct, rem_hi, rem_lo, componentId]`(0xFFFF=不明)、QC35=単一 `[pct]` |
| ファーム | [0.5] | ASCII 版番号 |
| 機種名 | [1.2] | `[flag, ...UTF-8...]`(payload[1:]) |
| CNC 状態(Ultra) | [1.5] | `[current, numSteps, flags]`(numSteps=11→レンジ 0..10) |
| EQ(Ultra) | [1.7] | 3×`[min=0xf6(-10), max=0x0a(+10), value, bandId]`(band 0/1/2=Bass/Mid/Treble) |
| ボタン | [1.9] | `[buttonId, event, action, supportedMask(4)…]` |
| マルチポイント | [1.10] | ビットフラグ |
| サイドトーン | [1.11] | `[?, level, ?]`(payload[1]=level) |
| 現在モード(Ultra) | [31.3] | payload[0]=モード index |

書き込み(SETGET/START):

| 操作 | フレーム |
|---|---|
| NC(QC35 ANR) | `01 06 02 01 <lv>` — lv: 0=off,1=high,2=wind,3=low(**ワイヤ値で扱う。ラベルは実装ごとにブレる**) |
| CNC ライブ(Ultra) | `31 0a 02 05 <cnc> <autoCNC> <spatial> <wind> <anc>` — 例 CNC5 は `31 0a 02 05 05 00 00 00 01` |
| EQ(Ultra, 1 バンドずつ×3) | `01 07 02 02 <value(signed)> <bandId>` |
| モード切替(Ultra) | `31 03 05 02 <index> <voicePrompt>` |
| 電源 OFF | `07 04 05 01 00` |

### 2.4 CNC(Ultra)の注意

- **スケールは反転**: 0=最大 ANC、10=最大外音取り込み。UI 移植時に注意。
- **可聴条件**: `anc=on` かつ `wind=off` のときだけレベル差が音になる(Wind Block が CNC DSP をマスク)。
- `autoCNC=1` は Runtime error 8 で拒否。手動 CNC(auto=0)のみ。
- ライブ制御は [31.10] AudioModesSettingsConfig SETGET(モード切替不要で即時反映)。

---

## 3. トランスポート

### 3.1 RFCOMM(主経路)

- **識別**: SDP に BMAP マーカー UUID **`00000000-deca-fade-deca-deafdecacaff`** を広告する機器が BMAP 対応(QC35 も広告 = 同族)。
- **実際に開くのは標準 SPP UUID `00001101-0000-1000-8000-00805f9b34fb`**。チャンネル番号は SDP から引く。引けない時のフォールバックは QC35 系=8、Ultra2 系=2(先行実装は `[9,2,8]` 総当たりも使うが、**Perch 方針では SDP 優先・引けなければ typed error でリトライへ**回す)。
- **送受信タイミング**: 送信後 **200ms 固定ディレイ**を置いてから recv(BMAP プロトコル要件)。GetAll 等の複数 STATUS は「500ms 無音まで読み続ける」ドレイン方式。
- **QC35 の init**: 接続直後に **GET [0.1](`00 01 01 00`)を送るまで無応答**。他機種は不要。
- ACK が来ないことがある → 状態が読めるまで CONNECT を再送する堅牢化(Android 実装の知恵)。

### 3.2 BLE/GATT(一部機種)

- サービス **`0xFEBE`**、書込/通知キャラは secure **`C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8`** / unsecure **`D417C028-9818-4354-99D1-2AC09D074591`**(secure 優先、無ければ unsecure)。
- スキャンはサービス UUID で絞る。`retrieveConnectedPeripherals` で既接続機器を先に拾う(音楽再生で常時接続のため広告を待たない)。
- **BLE だけ 20 バイト MTU の独自セグメント**が要る: 1 セグメント = `(maxIdx<<4)|index` の 1 バイトヘッダ + データ 19 バイト。受信側で index を見て再結合。RFCOMM にはこの層は無い。
- 書き込みは `.writeWithoutResponse` があればそれ、無ければ `.withResponse`。

### 3.3 選択戦略

bozo-bar 方式を actor に設計移植: **まず BLE を試し、(a) 最初の応答が BMAP `ERROR` op、または (b) 6 秒無応答なら RFCOMM に降格**。結果(機器ごとの有効トランスポート)を `AppSettingsStore` に永続化し、次回は直行。機種名での決め打ちはしない(capability 駆動)。

---

## 4. 機種判定とカタログ

- **Product ID** = Bluetooth Modalias `bluetooth:vVVVVpPPPPdDDDD` の `p` 直後 4 桁。全 Bose 共通 VID=`0x05A7`。macOS では IOBluetooth のデバイス情報/SDP から取得(bosectl の `bluetoothctl` 依存部は macOS 用に置換)。
- 主なカタログ(bosectl の 36 エントリより、ヘッドホン系抜粋):

| PID | 製品 | config | RFCOMM ch |
|---|---|---|---|
| 0x400C | QuietComfort 35 | qc35(ANR) | 8 |
| 0x4020 | QuietComfort 35 II | qc35 | 8 |
| 0x4024 | Noise Cancelling Headphones 700 | 未対応(将来) | 8(SaorCon) |
| 0x4039 | QuietComfort 45 | 未対応(将来) | — |
| 0x4082 | QC Ultra Headphones(2nd Gen) | qc_ultra2 | 2 |
| 0x4062 | QC Ultra Earbuds(2nd Gen) | qc_ultra2 | 2 |
| 0x4066 | QC Ultra Headphones(初代) | 未対応/BLE 経路 | BLE |

- **Perch の capability 駆動方針との整合**: 先行実装は機能アドレスをコード側テーブルで持つ(機器申告では引かない)。Perch は「機器申告から読む」流儀なので、**機能アドレス表は BoseCore のカタログに持たせつつ、"どのクエリに有効応答が返るか" で capability(UI 出し分け)を構成**する折衷にする。機種依存の焼き付けを最小化する。

---

## 5. Perch への層別マッピング

| 新規/流用 | モジュール | 内容 |
|---|---|---|
| **新規** | `BoseCore` | BMAP フレーム encode/decode/連結分割(`TandemFrame` の対置、より単純)。機能ビルダ/パーサ(NC/EQ/バッテリ/モード/ボタン/サイドトーン)。機種カタログ。BLE セグメンタ/リアセンブラ。 |
| **新規** | BLE トランスポート | `CBCentralManager` ベース。`0xFEBE`+secure/unsecure。Tandem の `TandemChannelOpening`/`OpenedChannel` 抽象に載せて BoseSession から透過利用。 |
| **一般化して流用** | `RFCOMMChannelHost`(現 TandemSession) | サービス探索クロージャを注入可能にして Sony/Bose で本体共有。Bose は SPP UUID `1101` を探す。 |
| **新規(設計は Tandem を踏襲)** | `BoseSession` | actor セッション状態機械。トランスポート選択(BLE→RFCOMM 降格)、200ms ディレイ、ドレイン、init パケット、CONNECT 再送、set→poll 確認。 |
| **射影** | UI(NotchKit/Perch) | Bose の NC/EQ/モード/サイドトーン/バッテリを Perch の `FeatureState`/`NoiseControl`/`ListeningMode` 等に射影し、ノッチ UI を Sony/Bose 共通で描く。capability の有無で出し分け(既存方針)。 |
| **拡張** | デバイス抽象 | `SessionService` の上に「接続機器が Sony か Bose か」を判定し、対応する Session を起動する層。UI は抽象化された機能インターフェースだけ見る。 |

---

## 6. 実装ロードマップ(支流の切り方)

各項目を `feature/bose-support` からの支流で進め、完成したら統合する。

1. `bose/protocol-core` — `BoseCore`: フレーム codec、operator、主要機能の builder/parser、カタログ。**純粋ロジックなので実機不要でテスト可能**。bosectl の captures を固定値テストに使う。
2. `bose/rfcomm` — `RFCOMMChannelHost` の一般化(サービス探索の注入)+ Bose SPP 探索。QC35/QC Ultra 2 の RFCOMM 接続。**実機必要**。
3. `bose/ble` — CoreBluetooth トランスポート + BLE セグメンテーション。QC Ultra 初代など。**実機必要**。
4. `bose/session` — `BoseSession` actor: トランスポート選択・接続手順・set→poll・状態機械。
5. `bose/device-abstraction` — Sony/Bose を束ねる上位層。UI が両対応。
6. `bose/ui` — ノッチ UI に Bose 機能を射影。文言 L() 対応。
7. `bose/tests-docs` — テスト網羅・由来表記(THIRD_PARTY_NOTICES)・README 追記。

**実機依存の切り分け**: 1 は実機ゼロで完成・テストできる(最初に着手する価値が高い)。2〜3 は Bose 実機が要る。実機到着前は 1 と、CoreBluetooth/IOBluetooth の疎通スキャフォールド(スキャン・SDP 照会が動くことの確認)まで進められる。

---

## 7. 落とし穴チェックリスト(実装時に参照)

- [ ] 送信後 200ms ディレイを入れる(省くと取りこぼす)
- [ ] QC35 は接続直後に GET [0.1] を送る(でないと無応答)
- [ ] 書き込みは SETGET(op2)/START(op5)。SET(op0) は認証で弾かれる
- [ ] NC はワイヤ値(0/1/2/3)で扱う。ラベルは実装ごとにブレる
- [ ] CNC スケールは反転(0=最大 ANC)。可聴には anc=on & wind=off
- [ ] autoCNC=1 は Runtime error 8。手動のみ
- [ ] プリセットモード(0-3)への書込みは拒否。カスタムスロット(4-10)のみ
- [ ] 複数 STATUS はドレイン(500ms 無音まで)で読む
- [ ] バッテリ payload 長は機種で違う(1B or 4B 群)
- [ ] SDP でチャンネルを引く。固定番号を焼き付けない
- [ ] BLE は 20B MTU セグメント必須。RFCOMM は不要
- [ ] BT アドレス等の個人情報をコード/ログ/docs に残さない(Perch 既存方針)

---

## 参考(クレジット)

- bosectl — https://github.com/aaronsb/bosectl (MIT, © 2026 Aaron Bockelie)
- bozo-bar — https://github.com/NerdySouth/bozo-bar (MIT, © 2026 Tristen)
- Bose_QC35_Android — https://github.com/DavidVentura/Bose_QC35_Android (MIT, © 2020 David Ventura)
- SaorCon — https://github.com/platinum95/SaorCon (MIT) / bose-macos-utility — https://github.com/lukasz-zet/bose-macos-utility (MIT)
