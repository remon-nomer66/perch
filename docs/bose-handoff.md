# Bose 対応 引き継ぎ作業書

このドキュメントは Bose(BMAP)対応の**作業を引き継ぐ人向け**。何が終わっていて、次に何を・どの順で・
どう検証しながら進めるかをまとめる。

- 統合ブランチ: **`feature/bose-support`**(ここに全部マージされている。最終的に `main` へ)
- ルール: **`feature/bose-support` に直接コミットしない。** 機能ごとに `bose/<機能>` の支流を切って作業し、
  レビュー後に `--no-ff` でマージする(これまでの全段階がこの運用)。
- 設計の正典(必ず先に読む):
  - [bose-support-plan.md](bose-support-plan.md) — 全体設計・9段階ロードマップ
  - [bose-frozen-spec.md](bose-frozen-spec.md) — **BMAP のバイト仕様の権威**(矛盾は実コード+実機キャプチャで裁定済み)
  - [bose-bmap-reference.md](bose-bmap-reference.md) — 機種カタログ・全機能アドレス・enum の参照表
  - [bose-device-contract.md](bose-device-contract.md) — **分離 UI 方針**(Sony/Bose は UI を共有しない)

---

## 1. 完了済み(段階1〜4 + パネル UI。全 490 テスト通過・2回コードレビュー承認)

| モジュール | 中身 | 状態 |
|---|---|---|
| `DeviceContract` | 薄い共有(`DeviceBrand`/`BatteryReading`/`DeviceHeadline`)。閉じたバー/メニュー/routing 用 | ✅ |
| `BoseCore`(13ファイル) | BMAP フレーム codec・ストリーム分解・機能 parser/builder(battery/CNC/ANR/EQ/firmware/name)・機種カタログ。**依存ゼロの純粋ロジック** | ✅ |
| `BoseSession`(6ファイル) | セッション要求モデル。operation 5種(single/multi/write→poll/cancel/PROCESSING)・注入クロック・接続手順。**mock でテスト済み、実トランスポート未接続** | ✅ |
| `BosePanel`(7ファイル) | Bose Ultra 2 のノッチパネル UI(4ページ)+ 状態射影 + view-model。**合成データで描画・プレビュー済み、実機未配線** | ✅ |
| `BosePanelPreview` | `ImageRenderer` でパネルの PNG を出す確認用ツール | ✅ |

**設計の要**: Sony(TandemCore/TandemSession/既存UI)は**一切触っていない**。Bose は完全に並列の別モジュール群。
共有は `DeviceContract` の薄い型と、閉じたバー/メニュー/セッション監督だけ(分離 UI 方針)。

---

## 2. これが「実機の壁」— ここから Bose 実機が必須

段階1〜4 は実機ゼロで作れたが、**ここから先は Bose 実機に実際に繋いで検証しないと進められない**。

### 前提(実機作業の共通ルール)
- **制御チャンネルは1本だけ。** `tools/control-lock.sh` 経由で必ず起動する(Sony と同じ。CLAUDE.md 参照)。
- **スマホ等の Bose 公式アプリを必ず切る**(繋いだままだとチャンネルを奪い合ってハングする)。
- 個人情報(Bluetooth アドレス・シリアル・機器個体名)を**コード/ログ/docs/テストに残さない**。
- 機種依存値を焼き付けない(`BoseDeviceConfig`/`BoseCatalog` にデータとして持つ)。frozen-spec に無い値を発明しない。

### 対象機種(第一段階で実機検証済みとして狙えるもの)
- **QC Ultra 2**(`0x4082` wolverine)= RFCOMM ch2、init 不要。**最優先**(bosectl の実キャプチャが最も厚い)
- QC35 / QC35 II(`0x400C`/`0x4020`)= RFCOMM ch8、init [0.1] 必須
- QC Ultra 初代(`0x4066`)は **BLE** 経路(段階8)

---

## 3. 段階5: RFCOMM トランスポート(次にやること)

支流 `bose/rfcomm` を切る。`BmapChannel`(Sources/BoseSession/BmapChannel.swift)に**実 RFCOMM トランスポートを conform** させる。

### やること
1. **IOBluetooth RFCOMM の実装**。Sony の `Sources/TandemSession/RFCOMMTransport.swift` の `RFCOMMChannelHost` が
   ほぼそのまま使える(専用スレッド・macOS 26 のコールバック欠落対策・スレッドリーク対策・teardown が実装済み)。
   **変えるのはサービス探索だけ**:
   - Sony は固定 UUID を引く。Bose は **BMAP マーカー UUID `00000000-deca-fade-deca-deafdecacaff`** で対応機を判定し、
     **標準 SPP UUID `00001101-0000-1000-8000-00805f9b34fb`** から RFCOMM チャンネルを引く(frozen-spec §3)。
   - **SDP で引けなければ typed error で失敗 → リトライへ**(固定チャンネル番号を焼き付けない。bosectl の 9/2/8 総当たりは採らない)。
   - `RFCOMMChannelHost` を「サービス探索クロージャ/strategy を注入できる」形に小さく一般化して Sony/Bose 共有するのが理想
     (Codex #4: 任意クロージャより `RFCOMMServiceLocator` 的な strategy 型が Swift6 concurrency 安全)。
2. 開いたチャンネルから `OpenedBmapChannel`(channel + inbound `AsyncStream<Data>`)を作り、
   `BoseSession.start(channel:inbound:config:...)` に渡す。**BoseSession 側は完成済み**。
3. **⚠️ 既知の前提改修**: `RFCOMMChannelHost` の inbound は `.bufferingNewest(256)` で、溢れると**無言で chunk を落とす**
   (Codex #7 / v1.0.0 レビュー H-01)。チェックサムの無い BMAP では1バイト欠落で framing が恒久崩壊するので、
   **共有する前に unbounded / 明示 overflow エラーへ改修**する。Sony 側にも効く改善。
4. **probe を先に作る**(`Sources/PerchProbe` の Bose 版、または既存 probe に Bose モード追加)。フル UI の前に、
   control-lock 下で「SDP でチャンネルを引く → init/GET → identity/battery が読める」ことを確認する。

### 検証(実機)
- QC Ultra 2 を接続・音声出力先にし、Bose アプリを切る → probe を control-lock で起動 → battery/firmware/CNC が読めるか。
- **frozen-spec の裏取り**: 実機の応答が frozen-spec のバイト仕様と合っているか(CNC バイト順 `current=payload[1]`、
  battery 形状、EQ の signed 等)。**合わなければ frozen-spec を訂正**してからテストを直す。
- QC35 では init [0.1] を送らないと無応答になることの確認。

---

## 4. 段階6: パネルUIのライブ配線 + セッション監督

支流 `bose/live-wiring`。`BosePanel` は完成しているので、実機データを流し込む配線が主。

### やること(`Sources/BosePanel/BosePanelModel.swift` と Perch 側)
1. **周期リフレッシュ**: 全機能 GET → `BoseDeviceSnapshot` 生成 → `model.apply(snapshot:)`。
   set→poll ガード(`AdjustmentGuard` 移植済み)は握っている間そのフィールドを更新しない実装済み。
2. **単一セッション監督**(Perch アプリ層。docs/bose-device-contract.md §3):
   - 接続機器のブランドを判定(`BoseCatalog` の Product ID / Sony は既存)。
   - **旧セッションを閉じ切ってから新セッションを開く**(制御1本ルール)。`enum ActiveSession { case sony/bose/none }` 的に。
   - 展開パネルをブランドで切替(Sony デバイス→既存パネル / Bose デバイス→`BosePanelView`)。**閉じたバーは共通**
     (`DeviceHeadline` を各セッションが作って NotchKit の閉じたバーへ)。
3. **NotchKit の器との統合**: `BosePanelView` は今スタンドアロンの黒角丸。共有のモーフィング器・now-playing 列・
   閉じたバーへの配線を Perch 側で(Sony と同じホスティング)。
4. **Localization ブリッジ**: `BosePanel.L10n.language` を Perch の `L10n.language` に同期(1行)。
   ※ BosePanel が独自 L を持つのは、Perch が executable で import できないため。

### 未配線のジェスチャ(BoseCore に builder が要る)
`BosePanelModel.swift` に TODO コメントあり。現状 optimistic 更新のみ:
- **モード選択 [31.6]**: ModeConfig の offset が frozen-spec §4 で一部未解明(STATUS[5]/[38-41]/[46])。
  **実機で片方向トグル + block 31 込みで再キャプチャして埋める**(frozen-spec §7 の TODO)。埋まったら BoseCore に
  builder を足し、他と同じ set→poll に昇格。
- **サイドトーン書き込み**: ワイヤ形式が未確定。実機で確認 → BoseCore builder → 配線。
- **CNC/ANC/wind/spatial [31.10]**: 送信は実装済み。機器が [31.10] GET に対応するなら EQ 同様 `writeThenPoll` に昇格可。

---

## 5. 段階7〜9(以降)

- **段階7 機能拡張**: 上記の未解明部分(モード編集・サイドトーン)を実機キャプチャで埋めて配線。
- **段階8 BLE**: QC Ultra 初代など。CoreBluetooth で `BmapChannel` に conform(サービス `0xFEBE`、secure/unsecure
  キャラ、**20バイトセグメント化は BLE トランスポート内**)。frozen-spec §3.2・bose-device-contract 参照。
  **RFCOMM 対応機種のリリースを BLE 待ちにしない**。
- **段階9 hardening**: fixture の PII 置換 validator、公証、README への Bose 追記、機種カタログ拡充。

---

## 6. 検証コマンド(共有 .build や実行中アプリを壊さないため)

複数エージェント/セッションが同居しうるので、ビルド/テストは**専用スクラッチパス**で:
```sh
swift build --scratch-path /tmp/spm-bose   # 任意の専用パス
swift test  --scratch-path /tmp/spm-bose
```
パネルの見た目確認:
```sh
swift run bose-panel-preview   # ImageRenderer で PNG 出力(Bluetooth 非接触)
```
実機に触る作業は必ず `tools/control-lock.sh`(status で BUSY なら起動しない)。

---

## 7. 参照実装(このリポジトリには含めない。事実データのみ参照)

`~/Development/bose-refs/` に clone 済み(MIT。**コードは写経せず事実だけ参照**、fixture/表をコピーする箇所には
MIT notice + 由来 commit を残す):
- **bosectl**(commit `5ccc41e`)= BMAP 最網羅。実機キャプチャ・14機種カタログ。frozen-spec の根拠。
- **bozo-bar**(Swift/macOS)= BLE 実装の見本(段階8)。
- **Bose_QC35_Android** = QC35 の生パケット。

> ⚠️ bosectl の captures には**シリアル[0.7]・デバイス鍵[0.12]・MAC 系**が生で残っている。fixture 化する前に
> 必ず synthetic 値へ置換すること(frozen-spec §11)。

---

## 8. まとめ: 次の一手

1. **`bose/rfcomm` を切る** → `RFCOMMChannelHost` の bufferingNewest を先に改修 → Bose SPP 探索を実装 → probe で疎通確認(実機)。
2. frozen-spec を実機で裏取り。
3. `bose/live-wiring` でパネルを実データに配線 + セッション監督。
4. 実機で耳を使って各コントロールが効くことを確認。

`BoseCore`/`BoseSession`/`BosePanel` は**実機が来れば繋ぐだけ**の状態まで作り込んである。難所(プロトコル解析・
セッションの並行処理・UI)は越えてあり、残りは主に「実トランスポート実装 + 実機での裏取り + 配線」。
