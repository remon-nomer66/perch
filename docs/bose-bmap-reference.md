# Bose BMAP リファレンス表(実装時の参照用)

`docs/bose-support-plan.md` の付録。先行実装 bosectl(MIT, © 2026 Aaron Bockelie)から
抽出した「事実データ」のみをまとめた参照表。**コードは移植せず、ID・バイト列・定数・
文字列という事実だけを参照する**(クリーンルーム原則)。

BMAP バージョン: **1.1.0**(一部ブロックの FblockInfo は 1.2.0 を返す)。
出典テスト機: QC Ultra 2 HP(`wolverine`, `0x4082`) / QC35(fw 4.8.1)。
凡例: 無印 = 事実 / **(未確認)** = 出典内で推測・未検証とされる事項。

---

## 1. 機種カタログ(全38エントリ)

USB VID 共通 `0x05A7`。BMAP SDP UUID `00000000-deca-fade-deca-deafdecacaff`。
Modalias `bluetooth:v05A7pXXXXd0000` の `p` 直後4桁が Product ID。`config=None` = 認識するが未実装。

### ヘッドホン

| PID | codename | 製品名 | config | 状況 |
|---|---|---|---|---|
| `0x400C` | wolfcastle | QuietComfort 35 | qc35 | 実装済 |
| `0x4015` | stetson | Hearphones | — | 未 |
| `0x4020` | baywolf | QuietComfort 35 II | qc35 | 実装済 |
| `0x4021` | atlas | ProFlight | — | 未 |
| `0x4024` | goodyear | Noise Cancelling Headphones 700 | — | 未 |
| `0x402B` | beanie | Hearphones II | — | 未 |
| `0x4039` | duran | QuietComfort 45 | — | 未 |
| `0x4066` | lonestarr | QuietComfort Ultra Headphones(初代) | — | 未(BLE経路) |
| `0x4075` | prince | QuietComfort Headphones | — | 未 |
| `0x4082` | wolverine | QuietComfort Ultra Headphones(2nd Gen) | qc_ultra2 | 実装済(テスト機) |

### イヤホン

| PID | codename | 製品名 | config | 状況 |
|---|---|---|---|---|
| `0x4012` | ice | SoundSport | — | 未 |
| `0x4013` | flurry | SoundSport Pulse | — | 未 |
| `0x4014` | powder | QuietControl 30 | — | 未 |
| `0x4018` | levi | SoundSport Free | — | 未 |
| `0x402C` | celine | Frames | — | 未 |
| `0x402D` | revel | Sport Earbuds | — | 未 |
| `0x402F` | lando | QuietComfort Earbuds | — | 未 |
| `0x403A` | gwen | Sport Open Earbuds | — | 未 |
| `0x404C` | celine_ii | Frames(2nd Gen) | — | 未 |
| `0x4060` | olivia | Frames Tempo | — | 未 |
| `0x4061` | vedder | Frames | — | 未 |
| `0x4062` | edith | QuietComfort Ultra Earbuds(2nd Gen) | qc_ultra2 | 実装済 |
| `0x4064` | smalls | QuietComfort Earbuds II | — | 未 |
| `0x4068` | serena | Ultra Open Earbuds | — | 未 |
| `0x4072` | scotty | QuietComfort Ultra Earbuds(初代) | — | 未 |

### スピーカー(参考・ヘッドホンアプリの対象外)

`0x400A` isaac(AE2 SoundLink) / `0x400D` foreman(SoundLink Color II) / `0x4010` folgers(Revolve) /
`0x4011` harvey(Revolve+) / `0x4017` kleos(SoundWear) / `0x4022` minnow(Micro) / `0x4085` troy(Plus) /
`0xA211` chibi(S1 Pro) / `0xBC58` billie(Micro 2) / `0xBC59` phelps(Flex) / `0xBC60` phelps_ii(Flex 2nd) /
`0xBC61` mathers(Flex 2) / `0xBC63` stan(Flex SE 2)。

> 注: architecture.md の図は「14 known」と古い。実カタログは 38。

---

## 2. Function Block 一覧(QC Ultra 2 実機観測)

| Block | 名前 | 観測 func |
|---|---|---|
| 0 | ProductInfo | 0,1,2,3,5,6,7,12,15,17,23 |
| 1 | Settings | 0,2,3,5,7,9,10,11,12,24,27 |
| 2 | Status | 0,2,5,16,21 |
| 3 | FirmwareUpdate(Ultra) / NoiseCancellation(QC35) **(未確認: 同ID別用途)** | 0,1,4,6,7,15,16 |
| 4 | DeviceManagement | 0-12 |
| 5 | AudioManagement | 0,1,3,4,5,7,13,17 |
| 6 | CallManagement | 0 |
| 7 | Control | 0,1,4 |
| 8 | Debug | 7,8 |
| 9 | Notification | 0,2 |
| 18 | Authentication | 0,1,9,11,12,13,24(移植対象外) |
| 31 | AudioModes | 1,3,4,6,8,9,10 |

---

## 3. 機能アドレス表

フレーム: `[fblock, func, flags, len, payload]`、`flags = (device_id<<6)|(port<<4)|(op&0x0F)`(通常 flags=op)。

### Settings [1.x](SETGET 認証不要)

| 機能 | addr | op | payload | 機種 |
|---|---|---|---|---|
| 機器名 | (1,2) | GET/SETGET | GET `[flag, UTF-8名]`(名は byte1〜)。SET UTF-8 | 両 |
| 音声プロンプト | (1,3) | GET/SETGET | 1B `(enabled<<5)|(lang&0x1F)` | 両 |
| CNC | (1,5) | GET(SET/SETGETは認証) | `[numSteps=11, current, flags]` flags bit0=enabled | Ultra |
| EQ | (1,7) | GET/SETGET | GET 3×`[min,max,cur,band]`。SET `[value(-10..+10), band]` band 0=Bass/1=Mid/2=Treble | Ultra |
| ANR(NC) | (1,6) | GET/SETGET | 1B `0=off,1=high,2=wind,3=low` | QC35 |
| ボタン | (1,9) | GET/SETGET | GET `[btnId,event,action,mask×4…]`。SET `[btnId,event,newAction]` | 両 |
| マルチポイント | (1,10) | GET/SETGET | GET bit1=有効。SET `0/1` | Ultra |
| サイドトーン | (1,11) | GET/SETGET | GET level=byte1。SET `[persist, level]` `0=off,1=high,2=med,3=low` | 両 |
| 自動一時停止 | (1,24) | GET/SETGET | `0/1` | Ultra |
| 自動応答 | (1,27) | GET/SETGET | `0/1` | Ultra |
| 自動オフ | (1,4) | SET(認証) | — | **(未確認)** |

### Status / ProductInfo [2.x][0.x]

| 機能 | addr | op | payload |
|---|---|---|---|
| バッテリ | (2,2) | GET | Ultra `[pct, rem_hi, rem_lo, compId]`(0xFFFF=不明) / QC35 `[pct]` |
| ファーム | (0,5) | GET | ASCII 版番号 |
| 型番名 | (0,15) | GET | UTF-8("Bose QC Ultra 2 HP") |
| シリアル | (0,7) | GET | ASCII |

### AudioManagement [5.x]

| 機能 | addr | op | payload |
|---|---|---|---|
| 音源照会 | (5,1) | GET のみ | `[supp_hi, supp_lo, activeType, …]` activeType `0=none,1=BT(+MAC6),2=AUX` |
| 再生操作 | (5,3) | START(認証) **(未確認: 実装未検証)** | 1B `0=STOP,1=PLAY,2=PAUSE,3=FWD,4=BACK,5=FF_press,6=FF_rel,7=REW_press,8=REW_rel` |

### DeviceManagement [4.x]

| func | 名前 | op | payload |
|---|---|---|---|
| 4 | ListDevices | GET | ペアリング済リスト |
| 8 | PairingMode | START→RESULT | `0x01`有効/`0x00`無効 |
| 9 | LocalMacAddress | GET | 自機 MAC |
| 12 | Routing(マルチP切替) | START→RESULT | `[0x82, MAC×6]`(bit7=UP方向) |

### Control [7.x]

| 機能 | addr | op | payload |
|---|---|---|---|
| GetAll | (7,1) | START→PROCESSING | — |
| 電源 | (7,4) | START→RESULT | `0`=off, `1`=on(認証不要) |

### AudioModes [31.x](START/SETGET 認証不要)

| 機能 | addr | op | payload |
|---|---|---|---|
| GetAll | (31,1) | START→PROCESSING | drain 必要 |
| モード切替 | (31,3) | START→RESULT / GET | `[modeIndex, voicePrompt(0=silent,1=音声)]` **動作確認済** |
| 起動時モード | (31,4) | SETGET **(未確認)** | — |
| モード設定 | (31,6) | SETGET(slot 5-10のみ) | 40B(下記)。preset 0-4 は Runtime error8 |
| お気に入り | (31,8) | SETGET | index |
| ライブ制御 | (31,10) | SETGET | 5B `[cnc, autoCNC, spatial, wind, anc]` 即時反映 |
| Reset | (31,9) | START(空payloadでInvalidData) **(未確認)** | — |

**ModeConfig SETGET(40B)**: `[0]=modeIndex(5-10) [1-2]=voicePrompt [3-34]=name(UTF-8,32,null埋) [35]=cnc(0-10) [36]=autoCNC [37]=spatial(0=off,1=room,2=head) [38]=wind [39]=anc`

**ModeConfig STATUS(48B)**: `[0]=idx [1-2]=prompt [3]=isUserEditable(0x01=可) [4]=isConfigured [6-37]=name [42]=cnc [43]=autoCNC [44]=spatial [45]=wind [47]=anc`。[38-41][46]は **(未確認)**。

**ライブ [31.10](5B)**: `[cnc, autoCNC, spatial, wind, anc]`。cnc 反転(0=最大ANC)。autoCNC=1 は Runtime error8。

---

## 4. enum 値表

**Operator**: 0=SET(認証) 1=GET 2=SETGET(block1,31は認証不要) 3=STATUS 4=ERROR 5=START(block31は不要) 6=RESULT 7=PROCESSING

**エラーコード**: 0=Unknown 1=Length 2=Chksum 3=FblockNotSupp 4=FuncNotSupp 5=OpNotSupp(認証) 6=InvalidData 7=DataUnavail 8=Runtime(preset lock等) 9=Timeout 10=InvalidState 15=InvalidTransition 20=InsecureTransport

**ボタンID**: 0x00 DistalCnc / 0x02 Vpa / 0x03 RightShortcut / 0x04 LeftShortcut / 0x10 Action(QC35) / 0x80 Shortcut(Ultra)

**ボタンイベント(0-12)**: 1 rising / 2 falling / 3 short_press / 4 single_press / 5 press_and_hold / 6 double_press / 7 double_press_hold / 8 triple_press / 9 long_press / 10 very_long / 11 very_very_long / 12 very_very_very_long

**アクションモード(18は欠番)**: 0 NotConfigured / 1 VPA / 2 ANC / 3 BatteryLevel / 4 PlayPause / 5 IncreaseCNC / 6 DecreaseCNC / 7 ToggleWakeWord / 8 SwitchDevice / 9 ConversationMode / 10 TrackForward / 11 TrackBack / 12 FetchNotifications / 13 WindMode / 14 Disabled / 15 ClientInteraction / 16 SpotifyGo / 17 ModesCarousel / 19 SpatialAudioMode / 20 LineInSwitch / 21 Linking

**音声言語(0-22)**: 0 UK English / 1 US English / 2 French / 3 Italian / 4 German / 5 EU Spanish / 6 MX Spanish / 7 BR Portuguese / 8 Mandarin / 9 Korean / 10 Russian / 11 Polish / 12 Hebrew / 13 Turkish / 14 Dutch / 15 Japanese / 16 Cantonese / 17 Arabic / 18 Swedish / 19 Danish / 20 Norwegian / 21 Finnish / 22 Hindi

**その他値**: ANR `0=off,1=high,2=wind,3=low` / Spatial `0=off,1=room,2=head` / Sidetone `0=off,1=high,2=med,3=low` / Source `0=none,1=BT,2=AUX`

**モード index — Ultra**(編集可 4-10): 0 Quiet / 1 Aware / 2 Immersion(空間・ヘッドトラック) / 3 Cinema(空間・固定) / 4 Home(可) / 5-10 空スロット(可)。preset 0-3 は SETGET 拒否。
**モード index — QC35**: 0 high / 1 low / 2 off。

---

## 5. モード/プロンプト名の文字列(L() 日英対訳の候補, APK 由来 AudioModesPrompt)

`(0,N)` → 名前(全 byte1=0):
0 NONE / 1 QUIET / 2 AWARE / 3 TRANSPARENT / 4 TRANSPARENCY / 5 MASKING / 6 COMFORT / 7 COMMUTE /
8 OUTDOOR / 9 WORKOUT / 10 HOME / 11 WORK / 12 MUSIC / 13 FOCUS / 14 RELAX / 15 FLIGHT / 16 AIRPORT /
17 DRIVING / 18 TRAINING / 19 GYM / 20 RUN / 21 WALK / 22 HIKE / 23 TALK / 24 CALL / 25 WHISPER /
26 HEARING / 27 LEARN / 28 PODCAST / 29 AUDIOBOOK / 30 CALM / 31 SLEEP / 32 MEDITATE / 33 YOGA /
34 IMMERSION / 35 STEREO / 36 CINEMA

---

## 6. 機種別 quirks

| 項目 | QC Ultra 2 | QC35 |
|---|---|---|
| RFCOMM ch | 2 | 8 |
| init パケット | 不要 | **GET [0.1] 必須**(でないと無応答) |
| NC | CNC [1.5]+ライブ [31.10](0-10) | ANR [1.6](off/high/wind/low 離散) |
| CNC スケール | 反転(0=最大ANC) | — |
| autoCNC | 拒否(=1 は error8) | — |
| 可聴条件 | anc=on & wind=off の時だけ CNC 差が音になる | — |
| EQ | 3-band [1.7] | 非対応 |
| 空間オーディオ | [31.6]/[31.10] | 非対応 |
| block 31(AudioModes) | あり | なし |
| モードスロット | 7編集可(4-10) | なし |
| マルチポイント | [1.10] | 非対応 |
| 自動一時停止/応答 | [1.24]/[1.27] | 非対応 |
| 電源オフ [7.4] | 対応 | 非対応 |
| リマップ対象ボタン | Shortcut(0x80) | Action(0x10) |
| バッテリ payload | 4B `[lvl,ff,ff,00]` | 1B(parse は byte0) |
| プラットフォーム | Qualcomm QCC-384 | CSR8670 |
| variant | 0x01 | 0x02 |

---

## 7. 未解明・要検証(Bose 実機が来たら埋める TODO)

- **ModeConfig STATUS の未知バイト** [38-41][46] のマッピング
- **block 3 の正体**(Ultra=FW更新, QC35=NC の同ID別用途か)
- **[31.4] DefaultMode SETGET** が実際に効くか(Timeout で不明)
- **[31.9] AudioModes Reset** の用途
- **ボタンリマップ [1.9]** の反映確認(echo は返るが実効果未検証)。Ultra Shortcut の supported action に未定義 22/25 が含まれる
- **[5.3] 再生操作** の実装・実機確認
- capture 手法の課題: 既存 capture は「開始値に戻して終える」設計 + block 31 未ポーリングのため機能→バイトの特定に至っていない。**片方向トグル + block 31 込みの再取得が必要**
- RFCOMM ch14=ステータスビーコン(`ff5502…`)/ch22=診断ストリーム/ch24=用途不明
- **認証は移植対象外**(SETGET 経路で全機能に到達できるため不要)

---

## クレジット

本表のデータは **bosectl**(https://github.com/aaronsb/bosectl, MIT © 2026 Aaron Bockelie)の
リバースエンジニアリング記録から抽出した事実。実装時は `THIRD_PARTY_NOTICES.md` に帰属を記載する。
