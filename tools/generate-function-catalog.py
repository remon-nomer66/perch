#!/usr/bin/env python3
"""SUPPORT_FUNCTION の機能コードと名前の対応表を Swift へ書き出す。

入力  tools/protocol-source/functiontypes.json
出力  Sources/TandemCore/Generated/TandemFunctionCatalog.swift

出力先は生成物であり、手で編集しない。由来と更新手順は
tools/protocol-source/NOTICE.md を参照。
"""

from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "tools" / "protocol-source" / "functiontypes.json"
OUTPUT = ROOT / "Sources" / "TandemCore" / "Generated" / "TandemFunctionCatalog.swift"

# 上流の JSON はテーブルを NO_1 / NO_2 という名前で持つ。
TABLES = [("NO_1", "one"), ("NO_2", "two")]

HEADER = """\
// このファイルは tools/generate-function-catalog.py が生成する。手で編集しない。
//
// 由来: tools/protocol-source/functiontypes.json
//       https://github.com/andreabedini/soundconnectd (MIT OR Apache-2.0)
// 更新: python3 tools/generate-function-catalog.py

import Foundation

/// 機能コードがどちらの `CONNECT_RET_SUPPORT_FUNCTION` テーブルに属するか。
///
/// 同じ1バイトがテーブルごとに別の機能を指すため、コード単独では意味が定まらない。
/// 必ず読み出したテーブルと組にして扱う。
public enum TandemFunctionTable: UInt8, CaseIterable, Equatable, Sendable {
  case one = 1
  case two = 2

  public init?(dataType: UInt8) {
    switch dataType {
    case TandemFrame.table1DataType: self = .one
    case TandemFrame.table2DataType: self = .two
    default: return nil
    }
  }

  public var dataType: UInt8 {
    switch self {
    case .one: TandemFrame.table1DataType
    case .two: TandemFrame.table2DataType
    }
  }
}

/// 機器が申告した機能コードを、人が読める名前へ変換する。
///
/// この対応表は名前しか持たない。ある機能を読み書きできるかどうかとは無関係で、
/// 名前が引けることを対応済みと解釈してはならない。
///
/// 未知のコードには `nil` を返す。新しい機種や新しいfirmwareが、この表にない
/// コードを申告することは正常な事態であり、失敗として扱わない。
public enum TandemFunctionCatalog {
"""


def swift_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_table(entries: dict[int, str], swift_name: str) -> list[str]:
    lines = [f"  private static let {swift_name}: [UInt8: String] = ["]
    for code in sorted(entries):
        lines.append(f"    0x{code:02X}: {swift_string(entries[code])},")
    lines.append("  ]")
    return lines


def main() -> int:
    if not SOURCE.exists():
        print(f"入力が見つからない: {SOURCE}", file=sys.stderr)
        return 1

    raw = json.loads(SOURCE.read_text())
    tables: dict[str, dict[int, str]] = {}
    for key, swift_case in TABLES:
        if key not in raw:
            print(f"入力に {key} がない", file=sys.stderr)
            return 1
        entries = {int(code): name for code, name in raw[key].items()}
        for code in entries:
            if not 0 <= code <= 0xFF:
                print(f"{key} のコードが1バイトに収まらない: {code}", file=sys.stderr)
                return 1
        tables[swift_case] = entries

    lines = [HEADER.rstrip("\n"), ""]
    lines += emit_table(tables["one"], "table1Names")
    lines.append("")
    lines += emit_table(tables["two"], "table2Names")
    lines.append("")
    lines += [
        "  private static func names(for table: TandemFunctionTable) -> [UInt8: String] {",
        "    switch table {",
        "    case .one: table1Names",
        "    case .two: table2Names",
        "    }",
        "  }",
        "",
        "  /// 既知なら名前、未知なら `nil`。",
        "  public static func name(table: TandemFunctionTable, code: UInt8) -> String? {",
        "    names(for: table)[code]",
        "  }",
        "",
        "  public static func isKnown(table: TandemFunctionTable, code: UInt8) -> Bool {",
        "    names(for: table)[code] != nil",
        "  }",
        "",
        "  /// 表示とレポート用。未知のコードも人が識別できる形で残す。",
        "  public static func label(table: TandemFunctionTable, code: UInt8) -> String {",
        "    if let name = names(for: table)[code] {",
        "      return name",
        "    }",
        "    return String(format: \"UNKNOWN_0x%02X\", code)",
        "  }",
        "",
        "  /// この表が名前を持つコードの数。生成物の欠落を検知するために公開する。",
        "  public static func knownCount(for table: TandemFunctionTable) -> Int {",
        "    names(for: table).count",
        "  }",
        "}",
        "",
    ]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines))
    print(f"{OUTPUT.relative_to(ROOT)} を生成した "
          f"(table1={len(tables['one'])}, table2={len(tables['two'])})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
