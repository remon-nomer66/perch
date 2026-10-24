import SpatialAudioKit
import Testing

@testable import Perch

// オンにするまでと、オンの間の判断を、観測の列（信号の有無・他プロセスの再生の有無・
// タップの許可判定）と、そのとき下る判断の表で確かめる。時間は既定の配分のまま:
// オンにするまでは 400ms ごとに見て6秒で見切る（15回目の観測が期限）。オンの間は
// 1秒ごとに見て、他が再生中なのに5秒無音なら手を打つ（5回目の観測）。他の再生が
// 3秒（3回）止まって初めて、それまでの無音と手当てを忘れる。
// 守りたい約束:
//  - 許可ありと分かれば、無音でもすぐオン（何も再生していなくてもオンにしておける）
//  - 許可なしなら期限で取り消し、理由は「許可なし」
//  - 判定できなければ実際の音で確かめ、届かなければ「音声を検出できない」で取り消す
//    （許可が無いとは決めつけない）
//  - 原音はミュートされているので、許可ありと確認できない限り無音のまま居座らない
//  - オンの間、何も再生していない無音は正常（他プロセスの状態が読めないときは、再生中
//    かもしれない側に倒す）。他が再生中なのに黙ったタップは1回作り直し、
//    それでも黙っていれば取り消して理由を出す。ただし、オンにしてから実際の音を一度でも
//    聞いていて、作り直したタップが許可ありと答えるなら、その無音は相手の音（黙ったまま
//    出力を開いているアプリ）なのでオンのまま
//  - 不変条件: 実際の音で裏付けられていない「許可あり」だけでは、他が再生中の無音に
//    居座らない（許可ありの答えそのものが誤っている環境でも、Mac の音を必ず戻す）
//  - 空間化した音の出力（AVAudioEngine）が止まれば、構成変更の作り直しを待つ猶予
//    （2秒）の後で1回作り直し、それでも止まるなら取り消す
//  - スリープ明けなどで観測の間が大きく空いたら、その回はどのタイマーも進めない

private typealias Decision = CaptureSupervisor.Decision

/// 1回の観測を supervisor に見せる。表の行もそれ以外のテストも、ここを通して流す。
/// 経過時間は、指定が無ければ名目の間隔そのもの（実時間の計測はコントローラの側）。
private func look(
  _ supervisor: inout CaptureSupervisor,
  signal: Bool,
  outputRunning: Bool = true,
  after elapsed: Duration? = nil,
  othersPlaying: () -> Bool? = { false },
  permission: () -> SystemAudioPermission
) async -> Decision {
  await supervisor.observe(
    hasSignal: signal,
    outputRunning: outputRunning,
    after: elapsed ?? supervisor.pollInterval,
    othersPlaying: { othersPlaying() },
    permission: { permission() }
  )
}

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

private func holds(_ count: Int) -> [Decision] {
  Array(repeating: .hold, count: count)
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
    name: "判定できない → 許可あり: 許可あり以外を見た後なので、タップを1回作り直す",
    looks: [.silentUnknown, .silentGranted, .silentGranted],
    decisions: [.hold, .rebuild, .commit]
  ),
  Scenario(
    name: "期限ちょうど（15回目）に、判定できないから許可ありへ変わっても作り直してからオン",
    looks: Array(repeating: .silentUnknown, count: 14) + [.silentGranted, .silentGranted],
    decisions: holds(14) + [.rebuild, .commit]
  ),
  Scenario(
    name: "期限ちょうど（15回目）に許可ありが来れば、期限より許可ありが勝つ（作り直してから）",
    looks: Array(repeating: .silentDenied, count: 14) + [.silentGranted, .silentGranted],
    decisions: holds(14) + [.rebuild, .commit]
  ),
  Scenario(
    name: "作り直した後の期限ちょうど（15回目）の許可ありは、そのままオン",
    looks: [.silentDenied, .silentGranted] + Array(repeating: .silentDenied, count: 14)
      + [.silentGranted],
    decisions: [.hold, .rebuild] + holds(14) + [.commit]
  ),
  Scenario(
    name: "一度でも許可なしと言われ、期限で判定できないなら、理由は許可なし",
    looks: [.silentDenied] + Array(repeating: .silentUnknown, count: 14),
    decisions: holdsUntilDeadline(then: .revoke(.permissionDenied))
  ),
]

@Test("オンにするまでの判断", arguments: scenarios)
private func confirmingDecisions(scenario: Scenario) async {
  var supervisor = CaptureSupervisor()
  var decisions: [Decision] = []
  for row in scenario.looks {
    decisions.append(await look(&supervisor, signal: row.signal, permission: { row.permission }))
  }
  #expect(decisions == scenario.decisions)
}

@Test("音が届いているなら、タップに許可を問い合わせない")
func signalNeedsNoPermissionProbe() async {
  var supervisor = CaptureSupervisor()
  var probes = 0
  let decision = await look(&supervisor, signal: true) {
    probes += 1
    return .granted
  }
  #expect(decision == .commit)
  #expect(probes == 0)
}

@Test("オンにした後は見張りへ移り、見る間隔も見張りのものになる")
func commitMovesToRunning() async {
  var supervisor = CaptureSupervisor()
  #expect(!supervisor.isRunning)
  #expect(supervisor.pollInterval == supervisor.timing.confirmInterval)
  _ = await look(&supervisor, signal: false) { .granted }
  #expect(supervisor.isRunning)
  #expect(supervisor.pollInterval == supervisor.timing.watchInterval)
}

// MARK: - オンの間の見張り

/// オンの間の1回の観測。
private struct WatchLook: Sendable {
  let signal: Bool
  /// 他のプロセスが音を出しているか。nil は読めなかった。
  let othersPlaying: Bool?
  var permission = SystemAudioPermission.granted
  /// 空間化した音の出力が動いているか。
  var outputRunning = true

  static let flowing = WatchLook(signal: true, othersPlaying: true)
  static let quiet = WatchLook(signal: false, othersPlaying: false)
  static let quietUnreadable = WatchLook(signal: false, othersPlaying: nil)
  static let stalled = WatchLook(signal: false, othersPlaying: true)
  static let stalledDenied = WatchLook(signal: false, othersPlaying: true, permission: .denied)
  static let stalledUnknown = WatchLook(signal: false, othersPlaying: true, permission: .unknown)
  /// 取り込みは届いているが、空間化した音を出す側が止まっている。
  static let deadOutput = WatchLook(signal: true, othersPlaying: true, outputRunning: false)
}

private struct WatchScenario: Sendable, CustomTestStringConvertible {
  let name: String
  let looks: [WatchLook]
  let decisions: [Decision]
  var testDescription: String { name }
}

/// 他が再生中の無音が期限（5回目）に達するまでの観測。
private func stall(_ count: Int = 5, _ look: WatchLook = .stalled) -> [WatchLook] {
  Array(repeating: look, count: count)
}

private let watchScenarios: [WatchScenario] = [
  WatchScenario(
    name: "音が流れている間は何もしない",
    looks: Array(repeating: .flowing, count: 12),
    decisions: holds(12)
  ),
  WatchScenario(
    name: "何も再生していない間の無音は正常: いつまでもオンのまま",
    looks: Array(repeating: .quiet, count: 30),
    decisions: holds(30)
  ),
  WatchScenario(
    name: "他プロセスの再生が読めないときは再生中かもしれない側に倒す: 黙ったタップを作り直し、取り消す",
    looks: Array(repeating: .quietUnreadable, count: 10),
    decisions: holds(4) + [.rebuild] + holds(4) + [.revoke(.captureLost)]
  ),
  WatchScenario(
    name: "他が再生中なのに無音が続けば、タップを1回作り直す",
    looks: stall(),
    decisions: holds(4) + [.rebuild]
  ),
  WatchScenario(
    name: "作り直して音が戻れば、そのままオン",
    looks: stall() + Array(repeating: .flowing, count: 8),
    decisions: holds(4) + [.rebuild] + holds(8)
  ),
  WatchScenario(
    name: "作り直しても無音のまま、タップが許可を判定できなければ取り消す（無音のまま居座らない）",
    looks: stall() + stall(5, .stalledUnknown),
    decisions: holds(4) + [.rebuild] + holds(4) + [.revoke(.captureLost)]
  ),
  WatchScenario(
    name: "実音を聞いた後で、作り直したタップが許可ありと答えるなら、無音は相手の音: オンのまま",
    looks: [.flowing] + stall() + stall() + stall(15),
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(15)
  ),
  WatchScenario(
    name: "実音を一度も聞いていなければ、作り直したタップが許可ありと答えても取り消す",
    looks: stall() + stall(),
    decisions: holds(4) + [.rebuild] + holds(4) + [.revoke(.captureLost)]
  ),
  WatchScenario(
    name: "作り直したタップの答えが揺れても、期限で効くのはその時の答え: 判定できなければ取り消す",
    looks: [.flowing] + stall()
      + [.stalled, .stalledUnknown, .stalled, .stalled, .stalledUnknown],
    decisions: [.hold] + holds(4) + [.rebuild] + holds(4) + [.revoke(.captureLost)]
  ),
  WatchScenario(
    name: "作り直したタップの答えが揺れても、期限で許可ありなら（実音を聞いた後は）オンのまま",
    looks: [.flowing] + stall()
      + [.stalledUnknown, .stalled, .stalledUnknown, .stalledUnknown, .stalled] + stall(5),
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(5)
  ),
  WatchScenario(
    name: "作り直したタップの答えに許可なしが混じれば、その場で取り消す",
    looks: [.flowing] + stall() + [.stalled, .stalledUnknown, .stalledDenied],
    decisions: [.hold] + holds(4) + [.rebuild, .hold, .hold, .revoke(.permissionDenied)]
  ),
  WatchScenario(
    name: "相手が黙って出力を開いている間も、ときどき許可を問い直し、取り消されていれば取り消す",
    looks: [.flowing] + stall() + stall() + stall(4) + [.stalledDenied],
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(4)
      + [.revoke(.permissionDenied)]
  ),
  WatchScenario(
    name: "問い直しで判定できなくなれば、無音のまま居座らずに取り消す",
    looks: [.flowing] + stall() + stall() + stall(4) + [.stalledUnknown],
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(4) + [.revoke(.captureLost)]
  ),
  WatchScenario(
    name: "相手が3秒鳴らし止めれば、次に黙ったときは改めて1回作り直せる",
    looks: [.flowing] + stall() + stall() + stall(3, .quiet) + stall(),
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(3) + holds(4) + [.rebuild]
  ),
  WatchScenario(
    name: "許可ありと確かめた後、相手の出力が一瞬止まっても忘れない（作り直しを連発しない）",
    looks: [.flowing] + stall() + stall() + [.quiet] + stall(5),
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + [.hold] + holds(5)
  ),
  WatchScenario(
    name: "許可ありと確かめた後、相手の出力が止まったり戻ったりを繰り返しても作り直さない",
    looks: [.flowing] + stall() + stall()
      + Array(repeating: [WatchLook.quiet, .stalled], count: 10).flatMap { $0 },
    decisions: [.hold] + holds(4) + [.rebuild] + holds(5) + holds(20)
  ),
  WatchScenario(
    name: "作り直した後に許可なしと分かれば、期限を待たずに許可なしで取り消す",
    looks: stall() + [.stalledDenied],
    decisions: holds(4) + [.rebuild, .revoke(.permissionDenied)]
  ),
  WatchScenario(
    name: "無音の途中で再生が一瞬止まっただけなら、数え直さない",
    looks: stall(4) + [.quiet] + stall(1),
    decisions: holds(4) + [.hold] + [.rebuild]
  ),
  WatchScenario(
    name: "無音の途中で再生が3秒止まれば、数え直す",
    looks: stall(4) + stall(3, .quiet) + stall(),
    decisions: holds(4) + holds(3) + holds(4) + [.rebuild]
  ),
  WatchScenario(
    name: "出力が一瞬止まっただけ（構成変更の作り直しで戻る）なら、何もしない",
    looks: [.deadOutput, .flowing, .deadOutput, .flowing],
    decisions: holds(4)
  ),
  WatchScenario(
    name: "出力が猶予を超えて止まれば、1回作り直す",
    looks: [.deadOutput, .deadOutput],
    decisions: [.hold, .rebuild]
  ),
  WatchScenario(
    name: "作り直しても出力が止まったままなら取り消す",
    looks: [.deadOutput, .deadOutput, .deadOutput, .deadOutput],
    decisions: [.hold, .rebuild, .hold, .revoke(.outputStopped)]
  ),
  WatchScenario(
    name: "作り直して出力が戻っても、すぐまた止まるなら取り消す（作り直しを繰り返さない）",
    looks: [.deadOutput, .deadOutput, .flowing, .flowing, .deadOutput, .deadOutput],
    decisions: [.hold, .rebuild, .hold, .hold, .hold, .revoke(.outputStopped)]
  ),
  WatchScenario(
    name: "作り直した出力がしばらく続けば、次に止まったときも改めて1回作り直せる",
    looks: [.deadOutput, .deadOutput] + Array(repeating: .flowing, count: 5)
      + [.deadOutput, .deadOutput],
    decisions: [.hold, .rebuild] + holds(5) + [.hold, .rebuild]
  ),
  WatchScenario(
    name: "音が戻った後なら、次に黙ったときにも改めて1回作り直せる",
    looks: stall() + [.flowing] + stall(),
    decisions: holds(4) + [.rebuild, .hold] + holds(4) + [.rebuild]
  ),
]

/// 許可ありで（無音のまま、つまり実音の裏付けなしに）オンにした直後の supervisor。
private func runningSupervisor() async -> CaptureSupervisor {
  var supervisor = CaptureSupervisor()
  let decision = await look(&supervisor, signal: false) { .granted }
  precondition(decision == .commit)
  return supervisor
}

@Test("オンの間の判断", arguments: watchScenarios)
private func watchDecisions(scenario: WatchScenario) async {
  var supervisor = await runningSupervisor()
  var decisions: [Decision] = []
  for row in scenario.looks {
    decisions.append(
      await look(
        &supervisor, signal: row.signal, outputRunning: row.outputRunning,
        othersPlaying: { row.othersPlaying }, permission: { row.permission }
      )
    )
  }
  #expect(decisions == scenario.decisions)
}

@Test(
  "不変条件: 実音で裏付けのない許可ありでは居座らない。他が再生中の無音は、答えがどうであれ10回以内に取り消す",
  arguments: [
    [SystemAudioPermission.granted],
    [.unknown],
    [.granted, .unknown],
    [.unknown, .granted],
  ]
)
func unprovenGrantNeverHoldsASilentMac(answers: [SystemAudioPermission]) async {
  var supervisor = await runningSupervisor()
  var asked = 0
  var revokedAt: Int?
  var reason: CaptureSupervisor.Revocation?
  for index in 0..<60 {
    let decision = await look(&supervisor, signal: false, othersPlaying: { true }) {
      defer { asked += 1 }
      return answers[asked % answers.count]
    }
    if case .revoke(let why) = decision {
      revokedAt = index
      reason = why
      break
    }
  }
  #expect(reason == .captureLost)
  #expect((revokedAt ?? .max) < 10)
}

@Test("見張りは、作り直すまでタップに許可を問い合わせない（音の流れているタップを揺らさない）")
func watchProbesOnlyAfterRebuilding() async {
  var supervisor = await runningSupervisor()
  var probes = 0
  let probe = { () -> SystemAudioPermission in
    probes += 1
    return .granted
  }
  for _ in 0..<4 {
    _ = await look(&supervisor, signal: false, othersPlaying: { true }, permission: probe)
  }
  #expect(probes == 0)
  let decision = await look(&supervisor, signal: false, othersPlaying: { true }, permission: probe)
  #expect(decision == .rebuild)
  #expect(probes == 0)
  _ = await look(&supervisor, signal: false, othersPlaying: { true }, permission: probe)
  #expect(probes == 1)
}

@Test("許可ありと確かめた後の問い直しは、期限ごとに1回だけ（タップを揺らし続けない）")
func vouchedTapIsAskedOncePerTimeout() async {
  var supervisor = await runningSupervisor()
  _ = await look(&supervisor, signal: true) { .granted }  // 実音を聞いた後
  var probes = 0
  let probe = { () -> SystemAudioPermission in
    probes += 1
    return .granted
  }
  func stalledLook() async -> Decision {
    await look(&supervisor, signal: false, othersPlaying: { true }, permission: probe)
  }
  for _ in 0..<5 { _ = await stalledLook() }  // 期限 → 作り直し（問い合わせない）
  for _ in 0..<5 { _ = await stalledLook() }  // 作り直したタップには毎回問い合わせる
  #expect(probes == 5)
  for _ in 0..<10 {  // 以後は期限ごとに1回
    let decision = await stalledLook()
    #expect(decision == .hold)
  }
  #expect(probes == 7)
}

// MARK: - 観測の間が大きく空いたとき

/// スリープ明けや、MainActor が長く止まった後の最初の観測。
private let wakeGap = Duration.seconds(3_600)

@Test("確認中に間が大きく空いた観測は、期限を進めない")
func longGapDoesNotSpendTheConfirmDeadline() async {
  var supervisor = CaptureSupervisor()
  var decisions: [Decision] = []
  decisions.append(await look(&supervisor, signal: false, after: wakeGap) { .denied })
  for _ in 0..<15 {
    decisions.append(await look(&supervisor, signal: false) { .denied })
  }
  #expect(decisions == holds(15) + [.revoke(.permissionDenied)])
}

@Test("出力が止まっていても、間が大きく空いた観測では猶予を使い切らない（構成変更の作り直しに任せる）")
func longGapDoesNotSpendTheOutputGrace() async {
  var supervisor = await runningSupervisor()
  var decisions: [Decision] = []
  decisions.append(await look(&supervisor, signal: true, outputRunning: false, after: wakeGap) {
    .granted
  })
  decisions.append(await look(&supervisor, signal: true, outputRunning: false) { .granted })
  decisions.append(await look(&supervisor, signal: true, outputRunning: false) { .granted })
  #expect(decisions == [.hold, .hold, .rebuild])
}

@Test("他が再生中の無音でも、間が大きく空いた観測では作り直しの期限を進めない")
func longGapDoesNotSpendTheStallTimeout() async {
  var supervisor = await runningSupervisor()
  var decisions: [Decision] = []
  decisions.append(
    await look(&supervisor, signal: false, after: wakeGap, othersPlaying: { true }) { .granted }
  )
  for _ in 0..<5 {
    decisions.append(await look(&supervisor, signal: false, othersPlaying: { true }) { .granted })
  }
  #expect(decisions == holds(5) + [.rebuild])
}

@Test("問い合わせ2つぶん遅れた観測（間隔の2倍＋問い合わせの上限）までは数える")
func lookDelayedByQuestionsStillCounts() async {
  var supervisor = await runningSupervisor()
  let timing = supervisor.timing
  let delayed = timing.watchInterval * 2 + timing.questionTimeout
  let decision = await look(&supervisor, signal: true, outputRunning: false, after: delayed) {
    .granted
  }
  #expect(delayed >= timing.outputGrace)
  #expect(decision == .rebuild)
}

@Test("音が流れている間は、他プロセスの再生も読みにいかない")
func flowingAudioNeedsNoProcessScan() async {
  var supervisor = await runningSupervisor()
  var scans = 0
  _ = await look(
    &supervisor, signal: true,
    othersPlaying: {
      scans += 1
      return true
    },
    permission: { .granted }
  )
  #expect(scans == 0)
}
