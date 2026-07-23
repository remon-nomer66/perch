import Foundation
import Testing

@testable import TandemCore

@Test func functionTableMapsToTheDataTypeItWasReadFrom() {
  #expect(TandemFunctionTable(dataType: TandemFrame.table1DataType) == .one)
  #expect(TandemFunctionTable(dataType: TandemFrame.table2DataType) == .two)
  #expect(TandemFunctionTable(dataType: 0x01) == nil)

  for table in TandemFunctionTable.allCases {
    #expect(TandemFunctionTable(dataType: table.dataType) == table)
  }
}

@Test func catalogNamesTheSameCodeDifferentlyInEachTable() {
  // 0x12 は table 1 では接続中コーデックの表示、table 2 では左右間の接続方式を指す。
  // コード単独では意味が定まらないことを、表そのもので示す。
  #expect(TandemFunctionCatalog.name(table: .one, code: 0x12) == "CODEC_INDICATOR")
  #expect(TandemFunctionCatalog.name(table: .two, code: 0x12) != "CODEC_INDICATOR")
}

@Test func catalogReportsUnknownCodesAsUnknownRatherThanFailing() {
  // 表にないコードは、新しい機種やfirmwareでは正常に起こる。名前が引けないことと、
  // 機器が壊れていることを混同しない。
  let unknown: UInt8 = 0x0E
  #expect(TandemFunctionCatalog.name(table: .one, code: unknown) == nil)
  #expect(TandemFunctionCatalog.isKnown(table: .one, code: unknown) == false)
  #expect(TandemFunctionCatalog.label(table: .one, code: unknown) == "UNKNOWN_0x0E")
}

@Test func catalogLabelsKnownCodesByName() {
  #expect(TandemFunctionCatalog.label(table: .one, code: 0x10) == "CONCIERGE_DATA")
  #expect(TandemFunctionCatalog.isKnown(table: .one, code: 0x10))
}

@Test func catalogRetainsEveryEntryOfTheGeneratedSource() {
  // 生成が途中で欠けても型検査は通るため、件数を固定しておく。上流を取り直して
  // 件数が変わった場合は、NOTICE.md の取得時点と併せてこの値を更新する。
  #expect(TandemFunctionCatalog.knownCount(for: .one) == 131)
  #expect(TandemFunctionCatalog.knownCount(for: .two) == 45)
}

@Test func everyDeclaredFunctionCanBeLabelled() {
  // 機器が申告した一覧をそのまま名前へ落とせること。未知が混ざっても全体は成立し、
  // 未知だけが `UNKNOWN_` として残る。レポートと表示はこの性質に依存する。
  let declared = [
    TandemSupportFunction(code: 0x10, version: 0x01),  // CONCIERGE_DATA
    TandemSupportFunction(code: 0x12, version: 0x01),  // CODEC_INDICATOR
    TandemSupportFunction(code: 0x0E, version: 0x01),  // 表にない
  ]

  let labels = declared.map { TandemFunctionCatalog.label(table: .one, code: $0.code) }

  #expect(labels == ["CONCIERGE_DATA", "CODEC_INDICATOR", "UNKNOWN_0x0E"])
  #expect(labels.allSatisfy { !$0.isEmpty })
}
