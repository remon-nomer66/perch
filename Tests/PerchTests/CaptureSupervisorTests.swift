import SpatialAudioKit
import Testing

@testable import Perch

// オンにするまでの判断を、観測の列（信号の有無・タップの許可判定）と、そのとき下る判断の
// 表で確かめる。時間は既定の配分（400ms ごとに見て、6秒で見切る = 15回目の観測が期限）。
// 守りたい約束:
//  - 許可ありと分かれば、無音でもすぐオン（何も再生していなくてもオンにしておける）
//  - 許可なしなら期限で取り消し、理由は「許可なし」
//  - 判定できなければ実際の音で確かめ、届かなければ「音声を検出できない」で取り消す
//    （許可が無いとは決めつけない）
//  - 原音はミュートされているので、許可ありと確認できない限り無音のまま居座らない

private typealias Decision = CaptureSupervisor.Decision

/// 1回の観測で supervisor に見せるもの。
private struct Look: Sendable {
  let signal: Bool
  let permission: SystemAudioPermission

  static let silentGranted = Look(signal: false, permission: .granted)
  static let silentDenied = Look(signal: false, permission: .denied)
  static let silentUnknown = Look(signal: false, permission: .unknown)
  static let audible = Look(signal: true, permission: .unknown)
}

private struct Scenario: Sendable, CustomTestStringConvertible {
  let name: String
  let looks: [Look]
  let decisions: [Decision]
  var testDescription: String { name }
}

/// 期限（15回目）の直前まで待ち、期限で `last` が下る判断の列。
private func holdsUntilDeadline(then last: Decision, after leading: Int = 0) -> [Decision] {
  Array(repeating: .hold, count: 14 - leading) + [last]
}

private let scenarios: [Scenario] = [
  Scenario(
    name: "許可あり: 無音でも1回目の観測でオン",
    looks: [.silentGranted],
    decisions: [.commit]
  ),
  Scenario(
    name: "音が届けば、許可の判定を待たずにオン",
    looks: [.audible],
    decisions: [.commit]
  ),
  Scenario(
    name: "許可なし: 期限まで待って（許可ダイアログの返事待ちかもしれない）、許可なしで取り消す",
    looks: Array(repeating: .silentDenied, count: 15),
    decisions: holdsUntilDeadline(then: .revoke(.permissionDenied))
  ),
  Scenario(
    name: "判定できない・無音: 期限で「音声を検出できない」として取り消す",
    looks: Array(repeating: .silentUnknown, count: 15),
    decisions: holdsUntilDeadline(then: .revoke(.noAudioDetected))
  ),
  Scenario(
    name: "判定できない・途中で音が届く: その時点でオン",
    looks: [.silentUnknown, .silentUnknown, .audible],
    decisions: [.hold, .hold, .commit]
  ),
  Scenario(
    name: "許可なし → 途中で音が届く: 実際の音を信じてオン",
    looks: [.silentDenied, .audible],
    decisions: [.hold, .commit]
  ),
  Scenario(
    name: "許可なし → 許可あり（ダイアログで許可された）: タップを1回作り直す",
    looks: [.silentDenied, .silentDenied, .silentGranted],
    decisions: [.hold, .hold, .rebuild]
  ),
  Scenario(
    name: "作り直した後の許可あり: もう作り直さずにオン",
    looks: [.silentDenied, .silentGranted, .silentDenied, .silentGranted],
    decisions: [.hold, .rebuild, .hold, .commit]
  ),
  Scenario(
    name: "作り直したタップには、改めて期限いっぱいの猶予がある",
    looks: [.silentDenied, .silentGranted] + Array(repeating: .silentDenied, count: 15),
    decisions: [.hold, .rebuild] + holdsUntilDeadline(then: .revoke(.permissionDenied))
  ),
  Scenario(
    name: "判定できない → 許可あり: 拒否を見ていないので作り直さずにオン",
    looks: [.silentUnknown, .silentGranted],
    decisions: [.hold, .commit]
  ),
  Scenario(
    name: "一度でも許可なしと言われ、期限で判定できないなら、理由は許可なし",
    looks: [.silentDenied] + Array(repeating: .silentUnknown, count: 14),
    decisions: holdsUntilDeadline(then: .revoke(.permissionDenied))
  ),
]

@Test("オンにするまでの判断", arguments: scenarios)
private func confirmingDecisions(scenario: Scenario) {
  var supervisor = CaptureSupervisor()
  let decisions = scenario.looks.map { look in
    supervisor.observe(
      hasSignal: look.signal,
      after: supervisor.pollInterval,
      permission: { look.permission }
    )
  }
  #expect(decisions == scenario.decisions)
}

@Test("音が届いているなら、タップに許可を問い合わせない")
func signalNeedsNoPermissionProbe() {
  var supervisor = CaptureSupervisor()
  var probes = 0
  let decision = supervisor.observe(
    hasSignal: true,
    after: supervisor.pollInterval,
    permission: {
      probes += 1
      return .granted
    }
  )
  #expect(decision == .commit)
  #expect(probes == 0)
}

@Test("オンにした後は見張りへ移る")
func commitMovesToRunning() {
  var supervisor = CaptureSupervisor()
  #expect(!supervisor.isRunning)
  _ = supervisor.observe(
    hasSignal: false, after: supervisor.pollInterval, permission: { .granted }
  )
  #expect(supervisor.isRunning)
}
