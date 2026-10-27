# Bose BMAP 確定仕様(spec-freeze)

`docs/bose-support-plan.md` の実装段階1(spec-freeze)の成果。実装前に、参照レポート間に残った
矛盾・未確認を**先行実装の現物コードと実機キャプチャの生バイトで裁定**したもの。実装(protocol-core
以降)はこの確定値に従う。未確認と明記した項目は実機が来るまで実装しない。

- 由来 commit: `bosectl` HEAD = **`5ccc41ed3153e961e2f3a9924ac8a70defcb633e`**
- clone: `~/Development/bose-refs/{bosectl, bozo-bar, Bose_QC35_Android}`(リポジトリには含めない)
- 確信度: `実機検証済`(capture 生バイトで裏取り)/ `複数実装一致` / `単一ソース` / `推測`
- 詳細な生バイト表は [bose-bmap-reference.md](bose-bmap-reference.md)、設計は [bose-support-plan.md](bose-support-plan.md)。

---

## 0. フレーミング(全機種共通・確定)

`[fblock, func, flags, payload_len, ...payload]`、`flags = (device_id<<6)|(port<<4)|(op&0x0F)`(通常 flags=op)。
連結パケットは各 `payload_len` で分割。op: `0=SET 1=GET 2=SETGET 3=STATUS 4=ERROR 5=START 6=RESULT 7=PROCESSING`。
BLE のみ 19バイト/セグメント(RFCOMM 不要)。
**確信度: 複数実装一致**(protocol.py ↔ BmapCodec.swift でバイト順完全一致)。

---

## 1. CNC [1.5] — バイト順を裁定 ★

参照実装が食い違った(bosectl=`[numSteps, current, flags]` / bozo-bar=`[current, numSteps, flags]`)。
スライダー操作の生 capture で決着: byte0 は `0x0b` 固定、byte1 だけがスライダーに追従。

```
[1.5] GET/STATUS payload(3B):
  offset 0 : numSteps    (0x0b=11 → レベル 0..10)
  offset 1 : currentStep (スライダー追従)   ← 現在値はここ
  offset 2 : flags        (bit0=enabled, bit1=userEnableDisable[反転]。capture では常に 0x03)
UI 最大値 = numSteps - 1 = byte0 - 1 = 10
```

**裁定: bosectl が正しい。Perch は `current = payload[1]`, `max = payload[0]-1` で読む。bozo-bar のバイト順を真似ない。**
**[1.5] への書き込みは Ultra 2 では auth 必須 → GET 専用。CNC 変更は [31.10](§3)を使う。**
確信度: GET レイアウト=実機検証済 / flags bit 意味=単一ソース(未検証) / [1.5]書込 auth=単一ソース+コード裏付け。

---

## 2. CONNECT / init / FW取得 — 機種別に確定 ★

| | QC35 | QC Ultra 2 |
|---|---|---|
| 接続後の init | **必須**: `[0.1] GET` = `00 01 01 00` を送るまで無応答 | 不要(いきなり GET が通る) |
| CONNECT ACK | `00 01 03 05` + FW 5バイト(ASCII, 例 "4.8.1") | — |
| FW 版の取得 | 上記 CONNECT ACK の 5バイト付随 | **`[0.5] GET`** → ASCII(例 "8.2.20+g34cf029") |

注: Ultra 2 の `[0.0]="1.1.0"`/`[0.1]="1.2.0"` はコンポーネント/BMAP版でありメイン FW ではない。FW は `[0.5]`。
確信度: QC35 init/ACK=単一ソース(Android)+bosectl 構造一致 / Ultra 2 FW=実機検証済。

---

## 3. Ultra 2 の NC/spatial/wind 書き込み [31.10] — 確定

```
[31.10] SETGET payload(5B): [cnc, autoCNC, spatial, wind, anc]
  cnc      : 0-10 (反転: 0=最大ANC, 10=最大アンビエント)
  autoCNC  : 常に 0 (=1 は Runtime error 8 で拒否)
  spatial  : 0=off, 1=room(固定), 2=head(追従)
  wind     : 0=off, 1=on
  anc      : 0=off, 1=on
```
**CNC の可聴差が出るのは `anc=on かつ wind=off` の時のみ**(Wind Block が CNC DSP をマスク)。
確信度: 実機検証済(parsers.py + NOTES)。

---

## 4. ModeConfig [31.6] — 既知/未解明を分離 ★

**capture に 31.x は含まれない**ため実機裏取りは無く、3実装(bosectl/NOTES/bozo-bar)のコード一致のみ。

**STATUS(48B)**: `[0]=modeIndex [1-2]=voicePrompt [3]=editable(1=可) [4]=configured [6-37]=name(UTF-8) [42]=cnc [43]=autoCNC [44]=spatial [45]=wind [47]=anc` … ★確実。
`[5]`(bosectl=unknown/bozo-bar=favorite で食い違い)・`[38-41]`・`[46]` … ✗**未解明(実機必要)**。

**SETGET(40B)**: `[0]=modeIndex [1-2]=voicePrompt [3-34]=name [35]=cnc [36]=autoCNC [37]=spatial [38]=wind [39]=anc`。

**実装方針: 「STATUS 48B を丸ごと保持 → 変更フィールドだけ差し替えて 40B SETGET を組む」**。未解明バイトは保存/エコーバックのみで解釈しない。
確信度: 既知 offset=3実装一致 / 未解明=実機必要。

---

## 5. モードスロット編集可否 — 確定 ★

- **editable = 4-10、preset(locked) = 0-3**(`EDITABLE_SLOTS=range(4,11)` と詳細表が一致。NOTES 散文の "0-4 locked" は誤り)。
- Mode 4(Home) が編集可なのは「アプリでユーザー作成された configured スロット」だから。
- **真の可否は静的リストではなく各 mode の STATUS[3](editable バイト)で判定**。`EDITABLE_SLOTS` は候補ヒント。
- preset(0-3) への SETGET は Runtime error 8。SET(op0) は全ブロック auth 必須(error 5)、SETGET は 4-10 で auth 不要。
- QC35 は block 31 非対応(`EDITABLE_SLOTS=[]`)。
確信度: 複数実装一致 / error 8/5 区別=単一ソース。

---

## 6. バッテリ [2.2] — 機種で形状差 ★

- **QC35 = 1バイト** `[pct]`(Android 実機)。
- **Ultra 2 = 4バイト群** `[pct, remaining_hi, remaining_lo, componentId]`(0xFFFF=不明)。capture `50 ff ff 00`=80% 実機一致。
- 長さ差の吸収: 先頭 % を取るだけなら両対応。**イヤホン L/R/ケースは 4バイトチャンクの繰り返しを componentId で識別**(bozo-bar のループ構造)だが、**イヤホンの実データは未検証=推測**。
確信度: QC35/Ultra 単一コンポーネント=実機 / 複数コンポーネント=推測。

---

## 7. EQ [1.7](Ultra 2)— 確定

```
GET(3×4B): [min, max, current, band_id] × バンド、すべて signed int8
  band_id: 0=Bass 1=Mid 2=Treble、min=-10(0xf6) max=+10(0x0a)
SETGET: [value(-10..+10 の &0xFF), band_id](2B)を band 0/1/2 の3回に分けて送る(一括でない)
```
capture `f60a0000 f60afe01 f60afa02` = Bass 0 / Mid -2 / Treble -6、実機一致。
確信度: GET=実機検証済 / SETGET=単一ソース(bosectl)+NOTES一致。

---

## 8. QC35 の NC(ANR)[1.6] — ワイヤ値確定 ★

```
SETGET: 01 06 02 01 <level>   STATUS: 01 06 03 02 <level> 0b (末尾=capabilities)
ワイヤ値: 0=off, 1=high, 3=low  (複数実装一致=確定)
         2=wind は bosectl 単一ソース。QC35 Android には値2が無く、QC35 では未サポート濃厚
```
Ultra 2 は ANR を使わない([1.6]=None)。NC は §1(読)+§3(書)。
確信度: 0/1/3=複数実装一致(実機) / 2=単一ソース・QC35 では未サポート濃厚。

---

## 9. config が持つべき軸(機種差の表現)— 確定

機種差は焼き付けず config データで表現(CLAUDE.md 方針と一致):

1. `rfcomm_channel`(QC35=8 / Ultra2=2。**完全に機種依存、焼き付け不可**)
2. `init_packet`(QC35=`(0,1)` GET / Ultra2=なし)
3. `features`: 機能名 → `(fblock, func)` + parser/builder 選択
4. `parser 選択`(ModeConfig 等は機種で差し替え可能に)
5. `editable_slots` + preset 範囲
6. `device_info`(product_id, variant, codename, platform)

確信度: 複数実装一致(コード直読)。

---

## 10. 第一段階の実装対象機種 — 確定

bosectl が `config != None`(バイトレベルで裏取り済み)なのは4機種のみ。実機 capture の厚みで序列:

| product_id | codename | 機種 | config | 第一段階 |
|---|---|---|---|---|
| **0x4082** | wolverine | QC Ultra Headphones (2nd Gen) | qc_ultra2 | **主対象**(生 capture・FW 8.2.20 で最も裏取りが厚い) |
| **0x4020** | baywolf | QuietComfort 35 II | qc35 | **対象**(Android 実機 + FW 4.8.1) |
| 0x400C | wolfcastle | QuietComfort 35 | qc35 | 対象(QC35 II と同系) |
| 0x4062 | edith | QC Ultra Earbuds (2nd Gen) | qc_ultra2 | **暫定**(config 流用宣言のみ・バッテリ複数コンポーネント未検証) |

その他 約31機種(NC700/QC45/QC Ultra 初代/QC Earbuds II 等)は catalog 収録のみ・**未実装**。
機種判定: Modalias の product_id → catalog lookup、不明時は暫定 qc_ultra2 フォールバック。
**→ 実機なしで固められるのはここまで。実装対象の第一目標は wolverine(0x4082)、次いで qc35 系。**

---

## 11. fixture の由来と PII 置換要件 ★(匿名化必須)

### 由来(provenance)— fixture 化時に記録する
- commit `5ccc41ed3153e961e2f3a9924ac8a70defcb633e`
- 根拠: `captures/*.json`(8件, before/after 形式)、`devices/parsers.py`、`constants.py`、`devices/{qc_ultra2,qc35}.py`、`NOTES.md`

### capture 内に残る PII(fixture 化前に synthetic 全置換)
部分マスク済みでも以下は生値が残存 — **そのまま fixture にしてはいけない**:

| addr | 内容 | 対応 |
|---|---|---|
| [0.7] | シリアルの平文先頭(ASCII 7文字) | 固定ダミーへ全置換 |
| [0.12] | 16バイトのデバイス鍵/トークン(未マスク) | 固定ダミーへ全置換 |
| [0.6]/[0.17] | 本体 BT MAC(OUI `68:f2:1f`=Bose 残存) | OUI ごと合成 MAC(例 `AA:BB:CC:00:00:01`)へ |
| [4.4]/[4.9]/[5.1] | ペア相手(スマホ)MAC | 合成 MAC へ |
| [0.2] | デバイス識別子らしき値 | 置換推奨 |
| top `mac` | 本体 MAC(部分マスク済) | 完全ダミー化 |

`[0.15]`(製品名)・版番号は PII でない。**この置換を通す validator を fixture 生成時に必須にする**
(CLAUDE.md「Bluetooth アドレス・個体名を残さない」に直結)。

---

## 12. 実装時に特に効く注意点(要約)

1. **CNC [1.5] は `current=payload[1]`, `max=payload[0]-1`**(bozo-bar のバイト順を真似ない)。
2. **Ultra 2 の CNC/spatial/wind/ANC 書き込みは [31.10] の5バイト**。autoCNC は常に 0。可聴差は anc=on & wind=off のみ。
3. **capture の `[5.7]/[5.13]` はライブテレメトリ(常時微変動)で設定レジスタではない**。capture は GET レイアウトの裏取りにのみ使う(設定書き込みの実アドレスは capture からは観測不能)。
4. **ModeConfig の未解明バイトは実機必要**。48B 保持 → 既知フィールドのみ差し替えて 40B SETGET が安全。
5. **機種差(channel/init/feature アドレス/parser)は必ず config 化**。焼き付け禁止。
6. **第一段階の確実な実装対象は wolverine(0x4082) と qc35 系(0x4020/0x400C)**。edith は暫定。

---

## クレジット

データ由来は bosectl(https://github.com/aaronsb/bosectl, MIT © 2026 Aaron Bockelie, commit `5ccc41e`)、
bozo-bar(MIT © 2026 Tristen)、Bose_QC35_Android(MIT © 2020 David Ventura)の
リバースエンジニアリング成果。実装時は独自コードで再実装し、fixture/表をコピーする箇所に MIT notice を付す。
