#!/usr/bin/env python3
"""対応申請の本文から、機械可読ブロックを取り出して検査する。

標準入力に Issue の本文（またはフォームの `report` フィールドの内容）を与える。
妥当なら整形したJSONを標準出力へ書き、終了コード0を返す。
妥当でなければ理由を標準エラーへ書き、終了コード1を返す。

    python3 tools/extract-device-report.py < body.md

本文の書式に依存しすぎないよう、取り出しは次の規則だけに頼る。

- 開きは、バッククォートの連続に `json` が続く行
- 閉じは、同じ長さのバッククォートだけの行

フェンスの長さが3つとは限らない。機器が送る文字列にバッククォートが含まれる場合、
生成側は中身より長いフェンスを使う。長さを決め打ちすると、まさにその機器の申請だけ
取りこぼす。
"""

from __future__ import annotations

import json
import re
import sys

OPENING = re.compile(r"^(`{3,})json\s*$")

# 文字列項目(機種名・firmware)に許す長さ。実在の機器名はこれよりずっと短い。
MAXIMUM_TEXT_LENGTH = 200

# 改行・制御文字。機器が申告する文字列には現れないので、含まれていれば
# 申請の体裁を借りた別物とみなして検査で落とす。
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f\u2028\u2029]")

# bot が返すコメントは Markdown として描画される。機種名などはバッククォートの
# inline code に入れて表示するが、値にバッククォートが含まれると code span が
# 壊れ、その後ろの @メンション・角括弧リンク・表区切りが生きてしまう。
# 描画に関与する文字を見た目の近い無害な文字へ置き換え、コメントを生成する側は
# 必ずこの置換後の値(payload の "display")だけを使う。
DISPLAY_REPLACEMENTS = str.maketrans({
    "`": "'",
    "|": "/",
    "[": "(",
    "]": ")",
    "@": "＠",
})

# 対応の可否を判断するために欠かせない項目。欠けていれば申請として成立しない。
REQUIRED = {
    "modelName": str,
    "firmwareVersion": str,
    "protocolIdentifier": int,
    "protocolFirstFlag": int,
    "protocolSecondFlag": int,
    "capabilityCode": int,
    "capabilityIdentifierLength": int,
    "table1Functions": list,
    "table2Functions": list,
}


def extract(body: str) -> str | None:
    lines = body.splitlines()
    for index, line in enumerate(lines):
        match = OPENING.match(line)
        if not match:
            continue
        fence = match.group(1)
        for close in range(index + 1, len(lines)):
            if lines[close].strip() == fence:
                return "\n".join(lines[index + 1:close])
    return None


def display_safe(value: str) -> str:
    """Markdown コメントへ埋め込んでも描画を乗っ取れない形にする。"""
    cleaned = CONTROL_CHARACTERS.sub(" ", value).translate(DISPLAY_REPLACEMENTS)
    if len(cleaned) > MAXIMUM_TEXT_LENGTH:
        cleaned = cleaned[:MAXIMUM_TEXT_LENGTH] + "…"
    return cleaned


def validate(payload: object) -> list[str]:
    problems: list[str] = []
    if not isinstance(payload, dict):
        return ["最上位がオブジェクトではない"]

    for key, expected in REQUIRED.items():
        if key not in payload:
            problems.append(f"{key} が無い")
            continue
        value = payload[key]
        # bool は int の派生だが、フラグの値としては受け取らない。
        if expected is int and isinstance(value, bool):
            problems.append(f"{key} が数値ではない")
        elif not isinstance(value, expected):
            problems.append(f"{key} の型が {expected.__name__} ではない")

    # 文字列項目の中身。型が合っていても、改行や制御文字が入っていれば
    # 機器の申告ではありえないので、申請として成立させない。
    for key in ("modelName", "firmwareVersion"):
        value = payload.get(key)
        if not isinstance(value, str):
            continue
        if not value.strip():
            problems.append(f"{key} が空")
        if CONTROL_CHARACTERS.search(value):
            problems.append(f"{key} に改行または制御文字が含まれる")
        if len(value) > MAXIMUM_TEXT_LENGTH:
            problems.append(f"{key} が長すぎる({MAXIMUM_TEXT_LENGTH}文字まで)")

    for table in ("table1Functions", "table2Functions"):
        for position, entry in enumerate(payload.get(table, []) or []):
            if not isinstance(entry, dict):
                problems.append(f"{table}[{position}] がオブジェクトではない")
                continue
            code = entry.get("code")
            version = entry.get("version")
            if not isinstance(code, int) or isinstance(code, bool) or not 0 <= code <= 255:
                problems.append(f"{table}[{position}].code が1バイトに収まらない")
            if not isinstance(version, int) or isinstance(version, bool):
                problems.append(f"{table}[{position}].version が数値ではない")
            # name は未知のコードで null になる。欠けているのは別の問題なので分ける。
            if "name" not in entry:
                problems.append(f"{table}[{position}].name が無い")

    return problems


def main() -> int:
    body = sys.stdin.read()

    block = extract(body)
    if block is None:
        print("機械可読ブロックが見つからない。アプリが生成した内容が"
              "書き換えられているか、貼り付けが欠けている。", file=sys.stderr)
        return 1

    try:
        payload = json.loads(block)
    except json.JSONDecodeError as error:
        print(f"機械可読ブロックがJSONとして読めない: {error}", file=sys.stderr)
        return 1

    problems = validate(payload)
    if problems:
        for problem in problems:
            print(f"- {problem}", file=sys.stderr)
        return 1

    # Issue 本文は第三者が書ける。コメント生成側が誤って生の値を Markdown へ
    # 流し込んでも実害が出ないよう、表示専用の置換済み文字列を並記する。
    # 同名キーが申請側にあっても、ここで必ず上書きする。
    report = {
        **payload,
        "display": {
            "modelName": display_safe(payload["modelName"]),
            "firmwareVersion": display_safe(payload["firmwareVersion"]),
        },
    }

    json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
