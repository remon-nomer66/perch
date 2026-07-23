import Foundation
import Testing

@testable import TandemCore

private func makeReport(
  modelName: String = "WH-1000XM5",
  table1Count: Int = 3
) -> TandemDeviceSupportReport {
  let functions = (0..<table1Count).map {
    TandemSupportFunction(code: UInt8(0x10 + $0), version: 1)
  }
  return TandemDeviceSupportReport(
    fingerprint: TandemDeviceFingerprint(
      protocolIdentifier: 0x0000_0102,
      protocolFirstFlag: 0x01,
      protocolSecondFlag: 0x00,
      capabilityCode: 0x04,
      capabilityIdentifierLength: 6,
      modelName: modelName,
      firmwareVersion: "3.0.1",
      table1Functions: functions,
      table2Functions: [TandemSupportFunction(code: 0x20, version: 1)]
    ),
    appVersion: "0.1.0"
  )
}

@Test func aShortReportIsCarriedEntirelyByTheURL() throws {
  let destination = try TandemIssueLink.destination(
    repository: "example/perch",
    report: makeReport(),
    template: "device-support.yml",
    labels: ["device-support", "triage"]
  )

  guard case .prefilled(let url) = destination else {
    Issue.record("短い報告はURLに収まるはず: \(destination)")
    return
  }

  let text = url.absoluteString
  #expect(text.hasPrefix("https://github.com/example/perch/issues/new?"))
  #expect(text.contains("template=device-support.yml"))
  #expect(text.contains("labels=device-support%2Ctriage"))
  #expect(text.contains("title="))
  #expect(text.contains("body="))
}

@Test func anIssueFormIsPrefilledByFieldIdRatherThanByBody() throws {
  // Issue Form(.yml) では本文は `body` ではなく、入れたいフィールドの `id` へ渡す。
  // Markdownテンプレートとの違いはここだけなので、名前を差し替えられるようにしてある。
  let destination = try TandemIssueLink.destination(
    repository: "example/repo",
    report: makeReport(),
    template: "device-support.yml",
    bodyParameter: "report"
  )

  guard case .prefilled(let url) = destination else {
    Issue.record("短い報告はURLに収まるはず")
    return
  }

  #expect(url.absoluteString.contains("report="))
  #expect(!url.absoluteString.contains("body="))
}

@Test func theFallbackDropsWhicheverParameterCarriedTheBody() throws {
  // 収まらないときに落とすのは本文を運んでいたパラメータであり、名前が既定と
  // 違っても取り残されない。
  let destination = try TandemIssueLink.destination(
    repository: "example/repo",
    report: makeReport(table1Count: 120),
    template: "device-support.yml",
    bodyParameter: "report"
  )

  guard case .bodyTooLong(let form, _) = destination else {
    Issue.record("長い報告はURLに収まらないはず")
    return
  }

  #expect(!form.absoluteString.contains("report="))
  #expect(form.absoluteString.contains("template=device-support.yml"))
}

@Test func aLongReportFallsBackToAnEmptyFormRatherThanBeingTruncated() throws {
  // 機能を多く申告する機器では本文がURLに収まらない。黙って削ると、申請者が送った
  // つもりの内容と実際の内容が食い違う。
  let report = makeReport(table1Count: 120)
  let destination = try TandemIssueLink.destination(
    repository: "example/perch",
    report: report,
    template: "device-support.yml"
  )

  guard case .bodyTooLong(let form, let body) = destination else {
    Issue.record("長い報告はURLに収まらないはず")
    return
  }

  // 本文は落とすが、題名とテンプレートは残す。開いた画面に文脈が残る。
  #expect(form.absoluteString.contains("template=device-support.yml"))
  #expect(form.absoluteString.contains("title="))
  #expect(!form.absoluteString.contains("body="))

  // 返す本文は切り詰めていない。
  #expect(body == report.body)
}

@Test func theLimitIsMeasuredOnTheEncodedURLNotTheRawText() throws {
  // 日本語はpercent-encodingでおよそ8倍になる。生の文字数で判定すると、収まると
  // 判断したURLが実際には収まらない。
  let report = makeReport()
  let rawLength = report.body.count

  let destination = try TandemIssueLink.destination(
    repository: "example/repo",
    report: report,
    byteLimit: rawLength + 200
  )

  // 生の長さに少し足した上限では収まらない、という形で膨張を固定する。
  guard case .bodyTooLong = destination else {
    Issue.record("encode後の長さで判定していない")
    return
  }
}

@Test func encodingLeavesOnlyUnreservedCharacters() {
  // `URLComponents` は `+` を素通しし、受け側で空白と解釈されうる。本文には任意の
  // 文字が入るため、残す文字を決め打ちする。
  #expect(TandemIssueLink.percentEncoded("a+b") == "a%2Bb")
  #expect(TandemIssueLink.percentEncoded("a b") == "a%20b")
  #expect(TandemIssueLink.percentEncoded("a&b=c") == "a%26b%3Dc")
  #expect(TandemIssueLink.percentEncoded("-._~") == "-._~")
  #expect(TandemIssueLink.percentEncoded("#フラグメント").hasPrefix("%23"))
}

@Test func encodingRoundTripsThroughTheStandardDecoder() {
  let source = "WH-1000XM5 `\n## 見出し` +&=?#/"
  let encoded = TandemIssueLink.percentEncoded(source)

  #expect(encoded.removingPercentEncoding == source)
}

@Test func aMalformedRepositoryIsRefusedRatherThanBuiltIntoTheURL() {
  // 設定値の誤りがURLの構造を変えてしまうのを防ぐ。
  for bad in ["", "owner", "owner/repo/extra", "owner/", "/repo", "own er/repo",
              "owner/re?po", "../../etc/passwd"] {
    #expect(throws: TandemIssueLinkError.malformedRepository(bad)) {
      _ = try TandemIssueLink.destination(repository: bad, report: makeReport())
    }
  }
}

@Test func aDeviceSuppliedNameCannotEscapeTheQueryString() throws {
  // 機種名は機器が送る値。クエリの区切りを持ち込まれても、パラメータが増えたり
  // 別のパラメータへ化けたりしてはならない。
  let report = makeReport(modelName: "XM5&labels=admin#x")
  let destination = try TandemIssueLink.destination(
    repository: "example/repo",
    report: report,
    labels: ["device-support"]
  )

  let text: String
  switch destination {
  case .prefilled(let url): text = url.absoluteString
  case .bodyTooLong(let form, _): text = form.absoluteString
  }

  // labels は指定した1つだけで、機器由来の値で増えていない。
  #expect(text.components(separatedBy: "labels=").count - 1 == 1)
  #expect(!text.contains("labels=admin"))
  #expect(!text.contains("#x"))
}
