# 由来と再配布条件

`functiontypes.json` は本プロジェクトの著作物ではない。取得元と条件を記録する。

| 項目 | 内容 |
| --- | --- |
| 取得元 | https://github.com/andreabedini/soundconnectd |
| ファイル | `docs/protocol/functiontypes.json` |
| 取得時点 | commit `2f8258048be5` (2026-07-20) |
| ライセンス | `MIT OR Apache-2.0`（`Cargo.toml` の `license` 欄、および `LICENSE-MIT` / `LICENSE-APACHE` の同梱による） |
| 本プロジェクトでの選択 | **MIT**。本リポジトリは AGPL-3.0 だが、MIT は AGPL-3.0 と互換であり、義務が著作権表示とライセンス文の保持のみで明確なため |

MITを選択するため、義務は著作権表示とライセンス文の保持のみである。リポジトリ直下の
`THIRD_PARTY_NOTICES.md` に表示を保持すること。

## なぜこの出典を選んだか

同じ対応表は `mos9527/SonyHeadphonesClient` の `libmdr/include/mdr/ProtocolV2.hpp`
にもあり、そちらもMITである。ただしそのファイルには次の記載がある。

```
// Extracted from Sound Connect iOS 12.2.0
```

識別子名はSonyアプリ内部のシンボルをそのまま転写したものであり、MITライセンスが
覆うのは転写した側の寄与に限られる。両者を突き合わせた結果は次のとおり。

| | mos9527（Sony由来） | soundconnectd（本ファイル） |
| --- | --- | --- |
| Table 1 | 130件 | **131件** |
| Table 2 | 44件 | **45件** |
| 共通166件のうち名前の不一致 | — | **0件** |

網羅度は本ファイルの方が広く、共通部分は完全に一致した。由来のより明確な側だけで
必要な情報が揃うため、こちらを採る。

## 更新方法

上流を取り直したうえで、生成物を作り直す。

```sh
curl -sL https://raw.githubusercontent.com/andreabedini/soundconnectd/main/docs/protocol/functiontypes.json \
  -o tools/protocol-source/functiontypes.json
python3 tools/generate-function-catalog.py
swift test
```

上の表の取得時点も併せて更新すること。

## この表が持たないもの

機能コードと名前の対応だけである。ペイロードの構造は含まない。ある機能を実際に
読み書きするには、`docs/protocol/` の該当章を読んで個別に実装する必要がある。
