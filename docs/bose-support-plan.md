# Bose(BMAP)対応 設計計画

Perch を Sony(Tandem)専用から、Bose(BMAP)にも対応させるための調査結果と設計方針。
先行実装 3 件(いずれも MIT)の精読に基づく。実装前の一次資料兼ロードマップ。

- 作業ブランチ: `feature/bose-support`(Bose 統合ブランチ)。機能ごとに `bose/<機能>` の支流を切って統合する。
- 参照実装(このリポジトリには含めない。クレジットのみ):
  - **bosectl**(aaronsb, MIT) — Python/Rust/C++。BMAP の最も網羅的な解析、実機キャプチャ、機種カタログ全38。
  - **bozo-bar**(NerdySouth/Tristen, MIT) — Swift/macOS。upstream は QC Ultra Gen1 向け BLE アプリと自称。
    ローカル文書が「BLE/RFCOMM 両対応・自動降格」とした点は upstream 実態と食い違うため、
    トランスポート選択ロジックの根拠は**実機で再確認するまで確定させない**(Codex #10)。
  - **Bose_QC35_Android**(DavidVentura, MIT) — Kotlin。QC35 の生バイト定義と ACK ワイルドカード方式。

> **ライセンスと参照の方針**(Codex #10):
> - プロトコルの技術的事実(アドレス・観測バイト・UUID)は**独自コードで再実装**する。fixture/表/文字列集合を
>   まとめてコピーする場合は、その箇所に MIT notice を付し `THIRD_PARTY_NOTICES.md` に帰属を記載する。
> - 参照元の **commit ハッシュ・対象ファイル・取得日**を記録する。
> - 「クリーンルーム」とは呼ばない(実チーム分離をしていないため)。「独自実装」と表現する。
> - APK/firmware 由来データは、先行実装作者の MIT 許諾だけで第三者権利まで解決するとは表現しない。

> **参照表**: 機種カタログ(全38)・機能アドレス・enum 値・モード名文字列・機種別 quirks・
> 未解明 TODO の全数表は [bose-bmap-reference.md](bose-bmap-reference.md) にある(bosectl の
> APK 解析成果を事実データとして抽出したもの)。実装時はそちらを引く。

---

## 1. 結論(先に要点)

1. **BMAP は Sony Tandem とは全くの別プロトコル**。フレーム形式・信頼性モデルが異なり、`TandemCore` のコーデックは流用不可。**`BoseCore` を新規に作る**。
2. **BMAP はフレーム構造・operator コードが機種共通の一枚岩**。ただし機種差は「露出機能とチャンネル」だけではない(Codex #8): QC35 は接続直後の init(GET [0.1])が必須、バッテリ payload 形状が違う(1B vs 4B群)、block 3 の意味が機種で異なる、NC が ANR(離散) vs CNC(連続)。機種差は**コード分岐でなくデータ(config)差**で表現するが、config が持つべき軸はチャンネルだけでなく init 要否・payload 形状・機能アドレス・パーサ選択を含む。
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
- **送受信タイミング(Codex #5 で訂正)**: 参照実装の「send → 200ms sleep → blocking recv」を**プロトコル要件と解釈しない**。受信は**常時 drain** し、送信レートは「settle window(直近送信からの最小間隔)」と「次回送信可能時刻」で管理する。これらの時刻は **injected clock**(注入されたクロック)で扱い、テスト可能にする。GetAll 等の複数 STATUS は「最初の応答 timeout + 500ms idle + 全体 deadline」で終了。既存 UI のドラッグ debounce は 90ms(main.swift)なので、Bose wire 側でも最小間隔の throttle/coalesce を設ける。
- **QC35 の init**: 接続直後に **GET [0.1](`00 01 01 00`)を送るまで無応答**。他機種は不要。→ config の軸に含める。
- ACK が来ないことがある → 状態が読めるまで CONNECT を再送する堅牢化(Android 実装の知恵)。

### 3.2 BLE/GATT(一部機種)

- サービス **`0xFEBE`**、書込/通知キャラは secure **`C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8`** / unsecure **`D417C028-9818-4354-99D1-2AC09D074591`**(secure 優先、無ければ unsecure)。
- スキャンはサービス UUID で絞る。`retrieveConnectedPeripherals` で既接続機器を先に拾う(音楽再生で常時接続のため広告を待たない)。
- **BLE だけ 20 バイト MTU の独自セグメント**が要る: 1 セグメント = `(maxIdx<<4)|index` の 1 バイトヘッダ + データ 19 バイト。受信側で index を見て再結合。RFCOMM にはこの層は無い。
- **BLE トランスポートの設計要件(Codex #6)**:
  - `CBCentralManager`/`CBPeripheral` を専用シリアルキュー(または専用 isolation)に閉じ込め、**非 Sendable オブジェクトを actor 外へ出さない**。
  - **notify 有効化が完了するまで `open` を成功扱いしない**。
  - `.writeWithoutResponse` は `canSendWriteWithoutResponse`/`peripheralIsReady(toSendWriteWithoutResponse:)` で backpressure を処理。`.withResponse` は各 fragment の delegate completion/error を待つ。
  - 実際の write 上限は `maximumWriteValueLength(for:)` から取る。**20 バイトの Bose セグメント規則は negotiated MTU とは別のプロトコル規則**である旨を型とコメントに残す。
  - 4bit `maxIdx/index` の範囲、最終 fragment、欠落・重複・逆順・途中切断・reassembly timeout を定義。
  - **RFCOMM フォールバックを開始する前に BLE transport を完全に閉じ切る**。

### 3.3 選択戦略(Codex #6 で訂正)

- **降格条件は「無応答 / 接続失敗 / 明示的な transport・security error」に限定**する。**BMAP `ERROR`(FuncNotSupp 等)を transport failure と扱ってはいけない** — ERROR は BMAP 通信が成立している証拠。当初案の「最初の応答が BMAP ERROR なら降格」は誤りなので破棄。
- 機種名での決め打ちはしない。有効トランスポートは実応答で判定する。
- 選択結果の永続化は §5 の `TransportPreferenceStore`(共通 module の protocol、Perch 側で UserDefaults adapter を注入)経由。**raw address・CBPeripheral UUID・機器名を保存せず**、既存 `DeviceIdentity` と同じ匿名化方針に従う。
- bozo-bar 由来の「BLE→RFCOMM 自動降格」は upstream 実態と食い違うため、**実機で挙動を確認するまで確定させない**(Codex #10)。

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

### 5.1 セッション層の設計(Codex #5 で具体化)

既存 `SessionCoordinator` は **TandemFrame parser / 交互 sequence / ACK lifecycle / 1要求1応答の continuation** を前提にしており、BMAP には流用できない。**再利用するのは `SessionEpoch`・`OperationID`・FIFO wire gate の考え方だけ**で、`RequestLifecycle`/`SessionRequesting` の型は流用しない。BoseSession の要求モデルは以下の operation 種別を定義する:

- **single response**: `STATUS`/`RESULT`/`ERROR` のいずれかで終了
- **multi response**: 関連 STATUS を蓄積。最初の応答 timeout + 500ms idle + 全体 deadline で終了
- **write then poll**: SETGET 応答を処理し、必要なら settle 後に GET を複数回 read-back
- **unsolicited notification**: in-flight 要求と同じ address の通知の扱いを定義
- **PROCESSING**: terminal ではなく継続。後続の RESULT/STATUS を待つ

※ 計画が set→実報告確認として挙げた `AdjustmentGuard`(main.swift)は**セッション機構ではなく UI の refresh 抑止**。read-back 検証はセッション層で別途実装する。

### 5.2 capability と write-trust の分離(Codex #8)

Sony は「device 申告からの feature inventory」と「verified profile による書き込み許可」を分けている(`DeviceVerification`/`VerifiedDevice`)。Bose も同じ4分離を持たせる:

- **capability**: GET 成功・FblockInfo・明示的 `FuncNotSupp` から構築(UI 出し分けの根拠)
- **transient unknown**: timeout/transport failure。**unsupported としてキャッシュしない**(次回再試行)
- **write trust**: 実機確認済み profile は書き込み可、未知 firmware は experimental/read-only 方針
- **product catalog**: 診断・検証 profile の選択にのみ使う。**UI 機能や RFCOMM チャンネルの fallback を決める根拠にしない**

### 5.3 層マッピング表

| 新規/流用 | モジュール | 内容 |
|---|---|---|
| **新規** | `BoseCore` | BMAP フレーム encode/decode/連結分割(`TandemFrame` の対置、より単純)+ ERROR 型。機能ビルダ/パーサ(NC/EQ/バッテリ/モード/ボタン/サイドトーン)。機種カタログ。BLE セグメンタ/リアセンブラ。 |
| **新規** | BLE トランスポート | `CBCentralManager` ベース。`0xFEBE`+secure/unsecure。§3.2 の isolation/backpressure/notify 完了要件を満たし、Tandem の `OpenedChannel`(write/close/inbound AsyncStream/MTU)抽象に載せる。 |
| **一般化して流用** | RFCOMM トランスポート | サービス探索は任意クロージャではなく **`RFCOMMServiceLocator` 相当の strategy を target 内に閉じ込める**(Swift 6 concurrency 安全性、Codex #4)。BMAP marker で対応判定し、どの SDP record から SPP チャンネルを確定するかまで定義。**前提: `RFCOMMChannelHost` の `.bufferingNewest(256)` によるサイレント chunk drop を先に修正**(unbounded / 明示 overflow failure / byte-count 付き bounded queue へ)。チェックサム無しの BMAP では 1 バイト欠落で framing が恒久崩壊する(Codex #7、v1.0.0 レビュー H-01 と同一の穴)。 |
| **新規(設計は §5.1)** | `BoseSession` | actor。トランスポート選択(§3.3 の限定降格)・接続手順(init/CONNECT 再送)・§5.1 の operation 種別・set→poll 確認・単一セッション arbiter。 |
| **新規** | 共通抽象 `DeviceControl` | Sony/Bose を UI から透過的に扱う共通コマンド/snapshot/capability/接続状態の型。**Sony 固有型(`TandemNoiseControlState` 等)を UI が直接触っている現状の結合を、この抽象へ移す作業を伴う(コストは過小評価しない、Codex #2)**。 |
| **共通 module** | `TransportPreferenceStore` protocol | 有効トランスポートの永続化。executable target の `AppSettingsStore` は BoseSession から参照不可のため protocol を共通 module に置き、Perch 側で UserDefaults adapter を注入(Codex #11)。 |
| **射影** | UI(NotchKit/Perch) | Bose の機能を `DeviceControl` 経由で描く。capability の有無で出し分け。 |

---

## 6. 実装ロードマップ(Codex #9 で組み替え)

横に長いレイヤ順(protocol→rfcomm→ble→session→…)は、最も不確実な BLE identity と共通型が後回しで実機失敗リスクが高い。**共通契約 + 縦切り**へ組み替える。各段階の**完了条件にテストと由来表記(MIT notice)を含める**(後段に送らない)。支流は `feature/bose-support` から切る。

1. **spec-freeze** — BMAP 表の矛盾解消(CNC/モードスロット/CONNECT・ACK/ModeConfig offset を確定)、各値の確認度・fixture 由来・対応宣言機種の明示。**実機なしで可**。
2. **device-contract**(`bose/device-abstraction` を前倒し)— 共通 snapshot/capability/command、接続状態、write trust、shared transport target のグラフを確定。**API を先に決める**。
3. **protocol-core**(`bose/protocol-core`)— フレーム codec / stream parser / ERROR / BLE segmenter。**純粋テストをここで実施**。※ 矛盾した capture から機能 parser/catalog を作り込むのは spec-freeze 完了後。
4. **scripted-session** — mock channel + injected clock で single/multi/set→poll/cancellation を完成。**実機なしで可**。
5. **RFCOMM 縦切り** — SDP 判定→接続→identity/battery→1機能の SETGET/read-back。**実機必要**(`control-lock.sh` 配下)。
6. **共通 UI 縦切り** — **Sony の回帰を保ちつつ** battery+NC など1機能を両ブランドで通す。
7. **機能拡張** — EQ/モード/サイドトーン等を順次。
8. **BLE** — target correlation 解決後。**RFCOMM 対応機種のリリースを BLE 待ちにしない**。
9. **release hardening** — 匿名化 validator、公証、README。

**実機依存の切り分け**: 1〜4 は Bose 実機ゼロで完成・テストできる(ここまで先に固める価値が高い)。5 以降は実機が要る。実機到着前は 1〜4 と、CoreBluetooth/IOBluetooth の疎通スキャフォールド(スキャン・SDP 照会が動くことの確認。BLE スタックは検証済み)まで進められる。

---

## 7. 落とし穴チェックリスト(実装時に参照)

- [ ] 送信レートは settle window + 次回送信可能時刻(injected clock)で管理。**受信は常時 drain**(「200ms sleep してから recv」ではない)
- [ ] QC35 は接続直後に GET [0.1] を送る(でないと無応答)
- [ ] 書き込みは SETGET(op2)/START(op5)。SET(op0) は認証で弾かれる
- [ ] NC はワイヤ値(0/1/2/3)で扱う。ラベルは実装ごとにブレる
- [ ] CNC スケールは反転(0=最大 ANC)。可聴には anc=on & wind=off
- [ ] autoCNC=1 は Runtime error 8。手動のみ
- [ ] プリセットモード(0-3)への書込みは拒否。カスタムスロット(4-10)のみ
- [ ] 複数 STATUS はドレイン(最初の応答 timeout + 500ms idle + 全体 deadline)で読む
- [ ] バッテリ payload 長は機種で違う(1B or 4B 群)
- [ ] SDP でチャンネルを引く。固定番号を焼き付けない
- [ ] BLE は 20B セグメント必須(negotiated MTU とは別規則)。RFCOMM は不要
- [ ] **降格は無応答/接続失敗/明示的 transport error に限定**。BMAP ERROR で降格しない
- [ ] **fixture 化する前に PII を synthetic 値へ置換**(機器名 [1.2]・シリアル [0.7]・音源 MAC [5.1]・ペアリング一覧 [4.4]・自機 MAC [4.9])。validator で拒否/置換
- [ ] トランスポート設定の永続化に raw address/CBPeripheral UUID/機器名を保存しない(`DeviceIdentity` の匿名化に従う)
- [ ] Bose probe も `tools/control-lock.sh` 配下で運用(制御セッションは 1 本)
- [ ] 参照コードは写経せず独自実装。fixture/表をコピーする箇所に MIT notice、由来(commit/日付)を記録

---

## 参考(クレジット)

- bosectl — https://github.com/aaronsb/bosectl (MIT, © 2026 Aaron Bockelie)
- bozo-bar — https://github.com/NerdySouth/bozo-bar (MIT, © 2026 Tristen)
- Bose_QC35_Android — https://github.com/DavidVentura/Bose_QC35_Android (MIT, © 2020 David Ventura)
- SaorCon — https://github.com/platinum95/SaorCon (MIT) / bose-macos-utility — https://github.com/lukasz-zet/bose-macos-utility (MIT)
