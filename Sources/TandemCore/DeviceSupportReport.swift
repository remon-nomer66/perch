import Foundation

/// 未対応機種の書き込み対応を申請するための、機器が申告した内容の要約。
///
/// 公開の場所へ貼られることを前提にしている。載せてよい値は
/// `TandemDeviceFingerprint` が持つものに限る。同型はBluetoothアドレス、個体識別子、
/// マルチポイントの接続先名を保持できないため、匿名性は型によって保たれる。
/// この要約に他の出所の値を足さないこと。
///
/// 送信は行わない。本文を組み立てるだけの純粋な変換であり、どこへ出すか、そもそも
/// 出すかどうかは利用側とその先の利用者が決める。
/// One read-only exchange with the device, kept as raw bytes so the actual structure of
/// a declared feature — band count, mode list, level range, timeout seconds — is on the
/// report even for a model nobody has, without anyone having to trust the app's parsing.
///
/// Only requests and their answers are captured; nothing is written. The bytes are the
/// device's declared parameters, which carry no address or individual identifier.
public struct TandemRawCapture: Equatable, Sendable {
  public let label: String
  public let request: [UInt8]
  public let response: [UInt8]

  public init(label: String, request: [UInt8], response: [UInt8]) {
    self.label = label
    self.request = request
    self.response = response
  }
}

public struct TandemDeviceSupportReport: Equatable, Sendable {
  public let fingerprint: TandemDeviceFingerprint
  public let appVersion: String
  /// The raw read-only exchanges gathered from the device, empty when none were taken.
  public let captures: [TandemRawCapture]

  public init(
    fingerprint: TandemDeviceFingerprint,
    appVersion: String,
    captures: [TandemRawCapture] = []
  ) {
    self.fingerprint = fingerprint
    self.appVersion = appVersion
    self.captures = captures
  }

  public var title: String {
    "[device] \(Self.inline(fingerprint.modelName)) (fw \(Self.inline(fingerprint.firmwareVersion)))"
  }

  /// 人が読む要約と、機械が読む同じ内容を1つの本文にまとめる。
  ///
  /// 要約だけでは自動処理が本文の書式に依存してしまい、JSONだけでは申請者が自分の
  /// 送る内容を確かめられない。両方を載せて、どちらの読み手も推測せずに済ませる。
  public var body: String {
    var lines: [String] = []

    lines.append("## 機器が申告した内容")
    lines.append("")
    lines.append("| 項目 | 値 |")
    lines.append("| --- | --- |")
    lines.append("| 機種名 | `\(Self.inline(fingerprint.modelName))` |")
    lines.append("| firmware | `\(Self.inline(fingerprint.firmwareVersion))` |")
    lines.append("| protocol | `\(Self.hex32(fingerprint.protocolIdentifier))`"
      + " flags `\(Self.hex8(fingerprint.protocolFirstFlag))`"
      + " `\(Self.hex8(fingerprint.protocolSecondFlag))` |")
    lines.append("| capability | code `\(Self.hex8(fingerprint.capabilityCode))`"
      + " / identifier長 \(fingerprint.capabilityIdentifierLength) |")
    lines.append("| 機能数 | table 1: \(fingerprint.table1Functions.count)"
      + " / table 2: \(fingerprint.table2Functions.count) |")
    lines.append("| アプリ | \(Self.inline(appVersion)) |")
    lines.append("")

    let unknown = unknownFunctionCount
    if unknown > 0 {
      lines.append("この機器は、本アプリが名前を持たない機能を \(unknown) 件申告している。"
        + "対応表より新しい機種またはfirmwareの可能性がある。")
      lines.append("")
    }

    lines += Self.functionSection("table 1", fingerprint.table1Functions, table: .one)
    lines += Self.functionSection("table 2", fingerprint.table2Functions, table: .two)
    lines += Self.captureSection(captures)

    lines.append("## 機械可読")
    lines.append("")
    // JSONは機器由来の文字列をそのまま運ぶ。バッククォートはJSONのエスケープ対象では
    // ないため、既定の3つのフェンスでは中身がブロックを閉じてしまう。CommonMarkに
    // 従い、中身に現れるどの連続よりも長いフェンスを使う。値を削らずに閉じ込める。
    let fence = Self.fence(enclosing: machineReadableJSON)
    lines.append("\(fence)json")
    lines.append(machineReadableJSON)
    lines.append(fence)
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("この内容には、Bluetoothアドレス、機器の個体識別子、"
      + "マルチポイントの接続先名を含まない。")
    lines.append("")
    lines.append("申告されていることと、実際にその機能を操作できることは別である。"
      + "書き込みの対応可否は実機での確認を経て決まる。")

    return lines.joined(separator: "\n")
  }

  public var unknownFunctionCount: Int {
    fingerprint.table1Functions.filter {
      !TandemFunctionCatalog.isKnown(table: .one, code: $0.code)
    }.count
      + fingerprint.table2Functions.filter {
        !TandemFunctionCatalog.isKnown(table: .two, code: $0.code)
      }.count
  }

  var machineReadableJSON: String {
    let payload = Payload(
      appVersion: appVersion,
      capabilityCode: Int(fingerprint.capabilityCode),
      capabilityIdentifierLength: fingerprint.capabilityIdentifierLength,
      firmwareVersion: fingerprint.firmwareVersion,
      modelName: fingerprint.modelName,
      protocolFirstFlag: Int(fingerprint.protocolFirstFlag),
      protocolIdentifier: Int(fingerprint.protocolIdentifier),
      protocolSecondFlag: Int(fingerprint.protocolSecondFlag),
      table1Functions: Self.payloadFunctions(fingerprint.table1Functions, table: .one),
      table2Functions: Self.payloadFunctions(fingerprint.table2Functions, table: .two),
      captures: captures
        .sorted { $0.label < $1.label }
        .map { PayloadCapture(label: $0.label, request: Self.hexBytes($0.request),
                              response: Self.hexBytes($0.response)) }
    )

    let encoder = JSONEncoder()
    // 同じ機器からは同じ本文が出るようにする。差分を取れることが、重複した申請を
    // 見分けるうえで効く。
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(payload),
          let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  // MARK: - 本文の組み立て

  private static func functionSection(
    _ heading: String,
    _ functions: [TandemSupportFunction],
    table: TandemFunctionTable
  ) -> [String] {
    guard !functions.isEmpty else { return [] }

    var lines = ["## \(heading)", ""]
    lines.append("| code | version | 機能 |")
    lines.append("| --- | --- | --- |")
    // 申告順ではなくコード順にする。順序が機器やfirmwareで揺れても、同じ機器なら
    // 同じ本文になる。
    for function in functions.sorted(by: { $0.code < $1.code }) {
      let name = TandemFunctionCatalog.label(table: table, code: function.code)
      lines.append("| `\(hex8(function.code))` | \(function.version) | `\(name)` |")
    }
    lines.append("")
    return lines
  }

  private static func captureSection(_ captures: [TandemRawCapture]) -> [String] {
    guard !captures.isEmpty else { return [] }
    var lines = ["## 生 capability 応答", ""]
    lines.append("機器が読み取りに答えた生バイト。宣言された機能の実構造(バンド数・モード・範囲・"
      + "秒数など)がここに表れる。読み取りのみで、書き込みはしていない。")
    lines.append("")
    lines.append("| 種別 | request | response |")
    lines.append("| --- | --- | --- |")
    for capture in captures.sorted(by: { $0.label < $1.label }) {
      lines.append("| `\(inline(capture.label))` | `\(hexBytes(capture.request))`"
        + " | `\(hexBytes(capture.response))` |")
    }
    lines.append("")
    return lines
  }

  private static func hexBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  private static func payloadFunctions(
    _ functions: [TandemSupportFunction],
    table: TandemFunctionTable
  ) -> [PayloadFunction] {
    functions
      .sorted { $0.code < $1.code }
      .map {
        PayloadFunction(
          code: Int($0.code),
          name: TandemFunctionCatalog.name(table: table, code: $0.code),
          version: Int($0.version)
        )
      }
  }

  // MARK: - 機器由来の文字列の扱い

  /// 機器が送ってきた文字列を、1行のコード表記へ収める。
  ///
  /// `modelName` と `firmwareVersion` は機器が送る値であり、こちらで検証していない。
  /// 本文はそのまま公開の場所へ貼られるため、改行とバッククォートに加えて縦棒も
  /// 落とす。縦棒はコード表記の中にあっても表のセル区切りとして解釈されるため、
  /// 残すと機器由来の文字列が表の列をずらしたり偽の列を注入できてしまう。
  /// エスケープ(`\|`)ではなく除去なのは、元の文字列に含まれるバックスラッシュと
  /// 組み合わさると打ち消される余地が残るからで、除去にはそれがない。値そのものは
  /// 機械可読の側にJSONの規則で正しく退避されるので、ここで削っても情報は失われない。
  static func inline(_ raw: String) -> String {
    let collapsed = raw.replacingOccurrences(
      of: "[\\r\\n\\t]+",
      with: " ",
      options: .regularExpression
    )
    let stripped = collapsed
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: "|", with: "")
    let trimmed = stripped.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "(空)" }
    return String(trimmed.prefix(64))
  }

  /// 中身を囲めるだけの長さを持つコードフェンス。
  ///
  /// CommonMarkでは、フェンスは中身に現れるどの連続よりも長ければブロックを保てる。
  static func fence(enclosing content: String) -> String {
    var longestRun = 0
    var currentRun = 0
    for character in content {
      if character == "`" {
        currentRun += 1
        longestRun = max(longestRun, currentRun)
      } else {
        currentRun = 0
      }
    }
    return String(repeating: "`", count: max(3, longestRun + 1))
  }

  private static func hex8(_ value: UInt8) -> String {
    String(format: "0x%02X", value)
  }

  private static func hex32(_ value: UInt32) -> String {
    String(format: "0x%08X", value)
  }

  // MARK: - 機械可読の形

  private struct PayloadFunction: Encodable {
    let code: Int
    /// 対応表にないコードでは `null`。件数を保ったまま未知であることを示す。
    let name: String?
    let version: Int

    private enum CodingKeys: String, CodingKey {
      case code, name, version
    }

    // 既定の合成は `nil` のときキーごと省く。それでは未知のコードが「名前の欄が無い」
    // 形になり、読み手が欠落と区別できない。明示的に null を書く。
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(code, forKey: .code)
      try container.encode(name, forKey: .name)
      try container.encode(version, forKey: .version)
    }
  }

  private struct PayloadCapture: Encodable {
    let label: String
    let request: String
    let response: String
  }

  private struct Payload: Encodable {
    let appVersion: String
    let capabilityCode: Int
    let capabilityIdentifierLength: Int
    let firmwareVersion: String
    let modelName: String
    let protocolFirstFlag: Int
    let protocolIdentifier: Int
    let protocolSecondFlag: Int
    let table1Functions: [PayloadFunction]
    let table2Functions: [PayloadFunction]
    let captures: [PayloadCapture]
  }
}
