# 第三者著作物の表示

本ソフトウェアは [LICENSE](LICENSE)（GNU AGPL-3.0）で提供する。第三者の著作物を含む部分、
および調査・実装の過程で参照した他プロジェクトについて、以下に記録する。

## ライセンス方針

本プロジェクトが **AGPL-3.0** であるため、次のライセンスのコード・データは、それぞれの
義務（著作権表示の保持、改変版のソース公開など）を満たせば **取り込み・改変・再配布できる**。

- **MIT** — 著作権表示とライセンス文を保持すればよい。
- **AGPL-3.0** — 本プロジェクトと同一ライセンス。帰属とソース公開で足りる（本リポジトリは公開されている）。
- **GPL-3.0** — GPLv3 と AGPLv3 は相互に互換（各 §13）。帰属とソース公開で組み込める。
  （※ GPLv2-only は AGPLv3 と非互換。取り込む前にバージョンを確認すること。）

したがって、下記「参照したプロジェクト」を将来取り込むこと自体に、ライセンス上の支障は無い。
一方、**OSS ライセンスの寛容さと無関係に取り込めないもの**がある。相手の OSS ライセンスは、
その中に含まれる**第三者（Sony）の著作物**までは許諾できないためである（末尾「Sony の権利」）。

---

## 取り込んでいるもの

### soundconnectd

`Sources/TandemCore/Generated/TandemFunctionCatalog.swift` は
`tools/protocol-source/functiontypes.json` から生成したものであり、同ファイルは
次のプロジェクトに由来する。

- 取得元: https://github.com/andreabedini/soundconnectd
- ファイル: `docs/protocol/functiontypes.json`
- 取得時点: commit `2f8258048be5` (2026-07-20)
- ライセンス: `MIT OR Apache-2.0`。本プロジェクトでは **MIT** を選択する

由来の詳細と更新手順は `tools/protocol-source/NOTICE.md` を参照。

```
MIT License

Copyright (c) 2026 Andrea Bedini

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 参照したプロジェクト

調査・検証の過程で次を参照した。いずれも本プロジェクト（AGPL-3.0）と互換であり、参照にも、
将来の取り込みにも法的支障は無い。実際に成果を取り入れた箇所は帰属を示す。

| プロジェクト | ライセンス | 参照・利用の内容 |
| --- | --- | --- |
| `Freeyourgadget/Gadgetbridge` | AGPL-3.0 | 旧世代機（WF-1000XM3 世代）のノイズコントロールのペイロード配列（`[enabled, wind, submode, 0x01, voice, level]`）を参照。**借用した実機 WF-1000XM3 で独立に検証済み**。ソースコードそのものは複製していないが、AGPL-3.0 同士で互換のため取り込みも許される |
| `mos9527/SonyHeadphonesClient` (`libmdr`) | MIT | 機能コード対応表の網羅度・名称の突き合わせに参照（`tools/protocol-source/NOTICE.md` に比較を記録）。カタログ本体は soundconnectd を採用。※`ProtocolV2T1.hpp` 等の **Sony 抽出部分**は下記「Sony の権利」を参照 |
| `maniacx/BudsLink`, `Bluetooth-Battery-Meter` | GPL-3.0 | 挙動の照合に参照。現時点でコード・データの取り込みは無い（取り込む場合も GPLv3↔AGPLv3 互換） |
| `Lakr233/NotchDrop` | MIT | ノッチ UI の挙動（ホバー時のわずかな伸び等）を参考にした。`Sources/NotchKit` は標準の macOS 手法による独自実装で、コードは複製していない（取り込む場合も MIT で可） |

---

## Sony の権利（OSS ライセンスと無関係に線引きするもの）

次は、相手の OSS ライセンスが寛容であっても取り込まない。中身が **Sony Group Corporation の
著作物**であり、OSS 側のライセンスがその部分まで許諾できないためである。

- `mos9527/SonyHeadphonesClient` の `libmdr/include/mdr/ProtocolV2T1.hpp` 等、**Sony アプリ
  からの抽出物**（"Extracted from Sound Connect iOS ..." と明記された識別子群）。
- `RealCrystalNight/Sony-Headphones-Metadata-and-Images` 等の **Sony 製品画像**。

本ソフトウェアはこれらを含まない。

---

## 商標

本ソフトウェアはSony Group Corporationと提携しておらず、同社の承認も受けていない。
"Sony"、"WH-1000XM"、"WF-1000XM"、"LinkBuds" その他の名称は、それぞれの権利者の
商標である。本ソフトウェアはこれらを、対応機器を説明する目的でのみ用いる。
