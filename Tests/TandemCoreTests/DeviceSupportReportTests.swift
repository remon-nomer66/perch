import Foundation
import Testing

@testable import TandemCore

private func makeFingerprint(
  modelName: String = "WH-1000XM5",
  firmwareVersion: String = "3.0.1",
  table1: [TandemSupportFunction] = [
    TandemSupportFunction(code: 0x12, version: 0x01),
    TandemSupportFunction(code: 0x10, version: 0x02),
  ],
  table2: [TandemSupportFunction] = [
    TandemSupportFunction(code: 0x20, version: 0x01)
  ]
) -> TandemDeviceFingerprint {
  TandemDeviceFingerprint(
    protocolIdentifier: 0x0000_0102,
    protocolFirstFlag: 0x01,
    protocolSecondFlag: 0x00,
    capabilityCode: 0x04,
    capabilityIdentifierLength: 6,
    modelName: modelName,
    firmwareVersion: firmwareVersion,
    table1Functions: table1,
    table2Functions: table2
  )
}

@Test func reportIncludesRawCapturesAsHexInBodyAndJSON() {
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(),
    appVersion: "0.1.0",
    captures: [
      TandemRawCapture(label: "eq.capability", request: [0x50, 0x04, 0x0B],
                       response: [0x51, 0x04, 0x0A, 0x0D]),
    ]
  )

  #expect(report.body.contains("生 capability 応答"))
  #expect(report.body.contains("`eq.capability`"))
  #expect(report.body.contains("50 04 0B"))
  #expect(report.body.contains("51 04 0A 0D"))
  // The machine-readable half carries the same bytes as hex strings.
  #expect(report.machineReadableJSON.contains("\"eq.capability\""))
  #expect(report.machineReadableJSON.contains("51 04 0A 0D"))
}

@Test func reportWithoutCapturesOmitsTheRawSection() {
  let report = TandemDeviceSupportReport(fingerprint: makeFingerprint(), appVersion: "0.1.0")
  #expect(!report.body.contains("生 capability 応答"))
}

@Test func reportNamesTheFunctionsTheDeviceDeclared() {
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(),
    appVersion: "0.1.0"
  )

  #expect(report.title == "[device] WH-1000XM5 (fw 3.0.1)")
  #expect(report.body.contains("CONCIERGE_DATA"))
  #expect(report.body.contains("CODEC_INDICATOR"))
}

@Test func reportOrdersFunctionsByCodeSoTheSameDeviceYieldsTheSameText() {
  // 申告順は機器やfirmwareで揺れうる。重複した申請を差分で見分けるために、
  // 本文は順序に依存してはならない。
  let ascending = makeFingerprint(table1: [
    TandemSupportFunction(code: 0x10, version: 0x02),
    TandemSupportFunction(code: 0x12, version: 0x01),
  ])
  let descending = makeFingerprint(table1: [
    TandemSupportFunction(code: 0x12, version: 0x01),
    TandemSupportFunction(code: 0x10, version: 0x02),
  ])

  let a = TandemDeviceSupportReport(fingerprint: ascending, appVersion: "0.1.0")
  let b = TandemDeviceSupportReport(fingerprint: descending, appVersion: "0.1.0")

  #expect(a.body == b.body)
}

@Test func reportKeepsUnknownFunctionsInsteadOfDroppingThem() {
  // 対応表より新しい機種は正常に起こる。未知を捨てると、まさに申請したい機能が
  // 本文から消える。
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(table1: [
      TandemSupportFunction(code: 0x10, version: 0x01),
      TandemSupportFunction(code: 0x0E, version: 0x01),
    ]),
    appVersion: "0.1.0"
  )

  #expect(report.unknownFunctionCount == 1)
  #expect(report.body.contains("UNKNOWN_0x0E"))
  #expect(report.body.contains("名前を持たない機能を 1 件"))
  #expect(report.machineReadableJSON.contains("\"name\" : null"))
}

@Test func reportCannotLeakAnIdentifierBecauseTheFingerprintHasNone() {
  // 匿名性は書式ではなく型で保つ。要約が持てる値は fingerprint の持ち物に限られる。
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(),
    appVersion: "0.1.0"
  )
  let text = report.body.lowercased()

  #expect(!text.contains("address"))
  #expect(!text.contains("uniqueid"))
  #expect(!text.contains("serial"))
  // 16進のMACらしい並びが本文に現れないこと。
  #expect(
    text.range(of: "([0-9a-f]{2}:){5}[0-9a-f]{2}", options: .regularExpression) == nil
  )
}

@Test func aDeviceSuppliedNameCannotBreakOutOfTheMarkdown() {
  // modelName は機器が送る値で、こちらは検証していない。本文は公開の場所へ貼られる
  // ため、コード表記や表のセルから抜け出せてはならない。
  let hostile = makeFingerprint(
    modelName: "WH-1000XM5`\n\n```\n## 乗っ取り",
    firmwareVersion: "3.0.1`"
  )
  let report = TandemDeviceSupportReport(fingerprint: hostile, appVersion: "0.1.0")

  #expect(!report.title.contains("\n"))
  #expect(!report.title.contains("`"))

  // 守りたい性質はバッククォートの数ではなく、機械可読ブロックが中身に閉じられずに
  // 取り出せること。本文から抜き出して解析できれば、抜け出しは起きていない。
  let extracted = try! #require(extractFencedJSON(from: report.body))
  let parsed = try! JSONSerialization.jsonObject(with: Data(extracted.utf8)) as! [String: Any]

  // 値そのものは削られず、JSONの規則で退避されている。
  #expect((parsed["modelName"] as? String)?.contains("乗っ取り") == true)
}

/// 本文から機械可読ブロックを、Actionsが行う手順と同じやり方で取り出す。
private func extractFencedJSON(from body: String) -> String? {
  let lines = body.components(separatedBy: "\n")
  guard let openIndex = lines.firstIndex(where: {
    $0.hasSuffix("json") && $0.dropLast(4).allSatisfy { $0 == "`" } && $0.count > 4
  }) else { return nil }

  let fence = String(lines[openIndex].dropLast(4))
  guard let closeOffset = lines[(openIndex + 1)...].firstIndex(where: { $0 == fence })
  else { return nil }

  return lines[(openIndex + 1)..<closeOffset].joined(separator: "\n")
}

@Test func aDeviceSuppliedNameCannotInjectTableColumns() {
  // 縦棒はコード表記の中にあってもセル区切りとして解釈されるため、残すと機器由来の
  // 文字列が表の列をずらしたり偽の列を注入できる。行の列数が値に左右されないこと。
  let hostile = makeFingerprint(
    modelName: "XM5 | 偽列 | 注入",
    firmwareVersion: "3.0.1|x"
  )
  let report = TandemDeviceSupportReport(fingerprint: hostile, appVersion: "0.1.0")

  let modelRow = report.body
    .components(separatedBy: "\n")
    .first { $0.hasPrefix("| 機種名 |") }
  #expect(modelRow != nil)
  // 2列の行は縦棒ちょうど3本。値がそこへ足せてはならない。
  #expect(modelRow?.filter { $0 == "|" }.count == 3)
  #expect(!report.title.contains("|"))

  // 値そのものは機械可読の側にJSONの規則で退避されている。
  #expect(report.machineReadableJSON.contains("偽列"))
}

@Test func anEmptyDeviceNameIsShownAsEmptyRatherThanAsNothing() {
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(modelName: "   "),
    appVersion: "0.1.0"
  )

  #expect(report.title.contains("(空)"))
}

@Test func machineReadableBlockCarriesWhatAnAllowlistEntryNeeds() {
  // 許可制の登録に必要な値が、書式の解釈なしに取り出せること。
  let report = TandemDeviceSupportReport(
    fingerprint: makeFingerprint(),
    appVersion: "0.1.0"
  )
  let json = report.machineReadableJSON
  let data = Data(json.utf8)
  let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

  #expect(parsed["modelName"] as? String == "WH-1000XM5")
  #expect(parsed["firmwareVersion"] as? String == "3.0.1")
  #expect(parsed["protocolIdentifier"] as? Int == 0x0000_0102)
  #expect(parsed["capabilityCode"] as? Int == 0x04)
  #expect(parsed["capabilityIdentifierLength"] as? Int == 6)
  #expect((parsed["table1Functions"] as? [[String: Any]])?.count == 2)
  #expect((parsed["table2Functions"] as? [[String: Any]])?.count == 1)
}
