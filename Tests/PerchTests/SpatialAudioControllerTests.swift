import Dispatch
import Foundation
import SpatialAudioKit
import Testing
import os

@testable import Perch

// コントローラの流れを、フェイクのエンジンで確かめる。実際のプロセスタップは作らない
// （作るとシステムオーディオ録音の許可ダイアログが出てしまう）。判断そのものは
// CaptureSupervisorTests の表にあり、ここではそれが結線どおりに効くことを見る:
// エンジンを作る・止める・作り直す、オン/取り消しの状態と理由、オンの間の見張り、
// 問い合わせを MainActor の外で時間を区切って行うこと。
// 壁時計の長さには頼らない。時間は観測ごとに進む時計で数え、戻らない問い合わせは
// テストが解放するまで戻らないラッチで表す（負荷がかかっても結果が変わらないように）。

/// 問い合わせごとに順に返す許可の判定（尽きたら最後のものを返し続ける）。問い合わせは
/// MainActor の外で走るので、記録はロックで守る。
private final class PermissionScript: Sendable {
  private struct State {
    var asked = 0
    var answered = 0
    var askedOnMain = false
  }

  private let answers: [SystemAudioPermission]
  /// あれば、問い合わせはこれが解放されるまで戻らない（戻らない問い合わせの代わり）。
  private let hold: DispatchSemaphore?
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(_ answers: [SystemAudioPermission], hold: DispatchSemaphore? = nil) {
    self.answers = answers
    self.hold = hold
  }

  /// 問い合わせが始まった回数と、戻った回数。
  var asked: Int { state.withLock { $0.asked } }
  var answered: Int { state.withLock { $0.answered } }
  var askedOnMain: Bool { state.withLock { $0.askedOnMain } }

  func answer() -> SystemAudioPermission {
    let onMain = Thread.isMainThread
    let index = state.withLock { state -> Int in
      defer { state.asked += 1 }
      state.askedOnMain = state.askedOnMain || onMain
      return state.asked
    }
    hold?.wait()
    state.withLock { $0.answered += 1 }
    return answers[min(index, answers.count - 1)]
  }
}

/// テストから許可の判定と信号を台本どおりに返すエンジン。
@MainActor
private final class FakeEngine: SpatialCaptureEngine {
  let script: PermissionScript
  private(set) var stopped = false
  /// 音が流れているか。流れている間は、読まれるたびに音のあるブロックが1つ増える。
  var flowing: Bool
  private var audibleBlocks = 0
  /// 見張りが信号を見た回数（1回の観測で1回読む）。時間の代わりに数える。
  private(set) var reads = 0
  private(set) var listener: ListenerOrientation?
  let estimatedBPM: Double? = nil
  /// 空間化した音を出す側（AVAudioEngine）が動いているか。
  var isOutputRunning: Bool

  init(script: PermissionScript, flowing: Bool, outputRunning: Bool) {
    self.script = script
    self.flowing = flowing
    isOutputRunning = outputRunning
  }

  var audibleBlockCount: Int {
    reads += 1
    if flowing { audibleBlocks += 1 }
    return audibleBlocks
  }

  var permissionProbe: (@Sendable () -> SystemAudioPermission)? {
    let script = self.script
    return { script.answer() }
  }

  func updateListener(_ orientation: ListenerOrientation) { listener = orientation }
  func setListenerDistance(ratio: Double) {}
  func stop() { stopped = true }
}

private struct StartFailure: Error {}

/// 呼ばれるたびに一定だけ進む時計。経過時間が観測の回数で決まり、テストが実時間に
/// 左右されない。`jump` を渡せば、n 回目の呼び出しだけ大きく進む（スリープ明けの代わり）。
@MainActor
private final class SteppingClock {
  private var current = ContinuousClock.now
  private var calls = 0
  private let step: Duration
  private let jump: (call: Int, by: Duration)?

  init(step: Duration, jump: (call: Int, by: Duration)? = nil) {
    self.step = step
    self.jump = jump
  }

  func now() -> ContinuousClock.Instant {
    calls += 1
    current += calls == jump?.call ? (jump?.by ?? step) : step
    return current
  }
}

@MainActor
private struct Harness {
  /// 作ったエンジンの記録と、次に作るエンジンの台本。
  @MainActor
  final class Engines {
    var built: [FakeEngine] = []
    /// n 個目に作るエンジンの許可の台本。尽きたら最後のものを使う。
    var scripts: [[SystemAudioPermission]]
    /// あれば、作るエンジンの問い合わせはこれが解放されるまで戻らない。
    var probeHold: DispatchSemaphore?
    /// 新しく作るエンジンで音が流れているか。
    var flowing: Bool
    /// 新しく作るエンジンの出力が動いているか。
    var outputRunning = true
    var failToStart = false
    /// 他のプロセスが音を出しているか（AudibleProcesses の代わり）。MainActor の外から
    /// 読まれるので、ロックの中に持つ。
    let playback = OSAllocatedUnfairLock<Bool?>(initialState: false)
    var othersPlaying: Bool? {
      get { playback.withLock { $0 } }
      set { playback.withLock { $0 = newValue } }
    }

    var allStopped: Bool { built.allSatisfy { $0.stopped } }

    init(scripts: [[SystemAudioPermission]], flowing: Bool) {
      self.scripts = scripts
      self.flowing = flowing
    }
  }

  let engines: Engines
  let controller: SpatialAudioController

  init(
    permissions: [[SystemAudioPermission]],
    flowing: Bool = false,
    timing: CaptureSupervisor.Timing = Harness.fastTiming,
    clockStep: Duration = .milliseconds(1),
    clockJump: (call: Int, by: Duration)? = nil,
    probeHold: DispatchSemaphore? = nil
  ) {
    let engines = Engines(scripts: permissions, flowing: flowing)
    engines.probeHold = probeHold
    self.engines = engines
    let defaults = UserDefaults(suiteName: "SpatialAudioControllerTests-\(UUID().uuidString)")!
    let clock = SteppingClock(step: clockStep, jump: clockJump)
    let playback = engines.playback
    controller = SpatialAudioController(
      defaults: defaults,
      makeEngine: { _, _ in
        if engines.failToStart { throw StartFailure() }
        let answers = engines.scripts[min(engines.built.count, engines.scripts.count - 1)]
        let engine = FakeEngine(
          script: PermissionScript(answers, hold: engines.probeHold),
          flowing: engines.flowing,
          outputRunning: engines.outputRunning
        )
        engines.built.append(engine)
        return engine
      },
      othersPlaying: { playback.withLock { $0 } },
      now: { clock.now() },
      timing: timing
    )
  }

  /// 時計は観測ごとに 1ms 進むので、時間の進みは観測の回数で決まる。刻みを詰めても
  /// 判断は変わらない。見張りは5回続けて無音なら手を打ち、他の再生が3回止まれば忘れる。
  /// 問い合わせの上限は長く取り、負荷がかかっても打ち切りが紛れ込まないようにする。
  static let fastTiming = CaptureSupervisor.Timing(
    confirmInterval: .milliseconds(1),
    confirmDeadline: .milliseconds(15),
    watchInterval: .milliseconds(1),
    stallTimeout: .milliseconds(5),
    quietReset: .milliseconds(3),
    outputGrace: .milliseconds(2),
    questionTimeout: .seconds(30)
  )

  /// `fastTiming` の問い合わせの上限だけを替えたもの。
  static func fastTiming(questionTimeout: Duration) -> CaptureSupervisor.Timing {
    var timing = fastTiming
    timing.questionTimeout = questionTimeout
    return timing
  }

  /// 監視タスク（MainActor 上の別タスク）に回す。条件が満ちるまで譲る。
  func drain(until condition: () -> Bool) async {
    for _ in 0..<5_000 where !condition() {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  /// 開始の確認が終わる（オンか取り消し）まで回す。
  func settle() async {
    await drain { !controller.isStarting }
  }
}

@MainActor
@Test("許可ありと分かれば、何も再生していなくてもすぐオンになる")
func grantedTurnsOnWhileSilent() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  #expect(harness.controller.isStarting)
  await harness.settle()

  #expect(harness.controller.isEnabled)
  #expect(harness.controller.errorMessage == nil)
  #expect(harness.controller.revocation == nil)
  #expect(harness.engines.built.count == 1)
  #expect(harness.engines.built.first?.stopped == false)
}

@MainActor
@Test("許可なしなら取り消し、エンジンを止めて許可の案内を出す")
func deniedRevokesWithPermissionGuidance() async {
  let harness = Harness(permissions: [[.denied]])
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(!harness.controller.isEnabled)
  #expect(harness.controller.revocation == .permissionDenied)
  // 文言そのものは下の「文言」で見る（表示言語は他のテストが切り替えうるため、ここでは比べない）。
  #expect(harness.controller.errorMessage != nil)
  #expect(harness.engines.allStopped)
}

@MainActor
@Test("判定できず音も届かなければ、許可ではなく「音声を検出できない」で取り消す")
func unknownAndSilentRevokesAsNoAudio() async {
  let harness = Harness(permissions: [[.unknown]])
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(!harness.controller.isEnabled)
  #expect(harness.controller.revocation == .noAudioDetected)
  #expect(harness.engines.allStopped)
}

@MainActor
@Test("判定できなくても、実際の音が届けばオン")
func unknownButAudibleTurnsOn() async {
  let harness = Harness(permissions: [[.unknown]], flowing: true)
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(harness.controller.isEnabled)
  #expect(harness.controller.revocation == nil)
}

@MainActor
@Test("確認中に許可されたら、タップを作り直してからオン")
func grantDuringConfirmationRebuildsOnce() async {
  let harness = Harness(permissions: [[.denied, .denied, .granted], [.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(harness.controller.isEnabled)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.built.first?.stopped == true)
  #expect(harness.engines.built.last?.stopped == false)
}

@MainActor
@Test("エンジンを始められなければ、確認には入らずにエラーを出す")
func startFailureReportsAnError() async {
  let harness = Harness(permissions: [[.granted]])
  harness.engines.failToStart = true
  harness.controller.setEnabled(true)

  #expect(!harness.controller.isStarting)
  #expect(!harness.controller.isEnabled)
  #expect(harness.controller.errorMessage != nil)
}

@MainActor
@Test("オフにするとエンジンを止め、前回の理由も消す")
func turningOffStopsTheEngine() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()
  harness.controller.setEnabled(false)

  #expect(!harness.controller.isEnabled)
  #expect(harness.engines.allStopped)
  #expect(harness.controller.errorMessage == nil)
  #expect(harness.controller.revocation == nil)
}

@MainActor
@Test("確認中もスイッチはオンを示し、オフにすれば確認を打ち切ってエンジンを止める")
func switchCancelsWhileConfirming() async {
  // 許可なしのまま期限までは長く待つ設定。打ち切らなければ確認が続く。
  let timing = CaptureSupervisor.Timing(
    confirmInterval: .milliseconds(1),
    confirmDeadline: .seconds(60)
  )
  let harness = Harness(permissions: [[.denied]], timing: timing)
  #expect(!harness.controller.isSwitchOn)
  harness.controller.setEnabled(true)
  #expect(harness.controller.isStarting)
  #expect(harness.controller.isSwitchOn)

  harness.controller.setEnabled(false)
  #expect(!harness.controller.isStarting)
  #expect(!harness.controller.isSwitchOn)
  #expect(harness.engines.allStopped)
  #expect(harness.controller.errorMessage == nil)
}

@MainActor
@Test("取り消しの後にもう一度オンにすれば、前回の理由は消えて改めて確かめる")
func retryClearsThePreviousReason() async {
  let harness = Harness(permissions: [[.denied], [.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()
  #expect(harness.controller.revocation == .permissionDenied)

  harness.controller.setEnabled(true)
  await harness.settle()
  #expect(harness.controller.isEnabled)
  #expect(harness.controller.revocation == nil)
  #expect(harness.controller.errorMessage == nil)
}

// MARK: - オンの間の見張り

@MainActor
@Test("オンの間、何も再生していなければ無音でもオンのまま。作り直しもしない")
func quietWhileNothingPlaysStaysOn() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()
  let engine = harness.engines.built[0]
  // 期限（5回）の何倍も見張らせる。
  await harness.drain { engine.reads >= 40 }

  #expect(engine.reads >= 40)
  #expect(harness.controller.isEnabled)
  #expect(harness.engines.built.count == 1)
}

@MainActor
@Test("他が再生中なのにタップが黙れば1回作り直し、音が戻ればそのままオン（向きも引き継ぐ）")
func stalledTapIsRebuiltAndRecovers() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()
  let pose = ListenerOrientation(yaw: 0.3, pitch: 0, roll: 0)
  harness.controller.updateListenerPose(pose, distanceRatio: 1)
  harness.engines.flowing = true
  harness.engines.othersPlaying = true
  await harness.drain { harness.engines.built.count == 2 }

  #expect(harness.engines.built.count == 2)
  let rebuilt = harness.engines.built[1]
  #expect(harness.engines.built[0].stopped)
  #expect(rebuilt.listener == pose)
  await harness.drain { rebuilt.reads >= 40 }
  #expect(harness.controller.isEnabled)
  #expect(harness.engines.built.count == 2)
  #expect(!rebuilt.stopped)
}

@MainActor
@Test("作り直しても黙ったまま、許可も判定できなければ取り消し、Mac の音を戻す（エンジンを止める）")
func stalledTapThatStaysSilentIsRevoked() async {
  let harness = Harness(permissions: [[.granted], [.unknown]])
  harness.controller.setEnabled(true)
  await harness.settle()
  harness.engines.othersPlaying = true
  await harness.drain { !harness.controller.isEnabled }

  #expect(!harness.controller.isEnabled)
  #expect(harness.controller.revocation == .captureLost)
  #expect(harness.controller.errorMessage != nil)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.allStopped)
}

@MainActor
@Test("実音を聞いた後で、作り直したタップが許可ありと答えるなら、相手が黙っているだけ: オンのまま")
func silentSourceWithAVouchedTapStaysOn() async {
  let harness = Harness(permissions: [[.granted]], flowing: true)
  harness.controller.setEnabled(true)
  await harness.settle()
  let first = harness.engines.built[0]
  await harness.drain { first.reads >= 3 }
  // 音が止まり、相手は黙ったまま出力を開いている。
  first.flowing = false
  harness.engines.flowing = false
  harness.engines.othersPlaying = true
  await harness.drain { harness.engines.built.count == 2 }
  let rebuilt = harness.engines.built[1]
  await harness.drain { rebuilt.reads >= 40 }

  #expect(harness.controller.isEnabled)
  #expect(harness.engines.built.count == 2)
  #expect(!rebuilt.stopped)
}

@MainActor
@Test("実音を一度も聞いていなければ、許可ありの答えだけでは居座らない: 作り直して取り消す")
func unprovenGrantDoesNotKeepTheMacSilent() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()
  #expect(harness.controller.isEnabled)
  harness.engines.othersPlaying = true
  await harness.drain { !harness.controller.isEnabled }

  #expect(harness.controller.revocation == .captureLost)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.allStopped)
}

@MainActor
@Test("作り直したタップが許可なしと答えれば、許可なしで取り消す（後から許可を取り消された）")
func revokedGrantIsReportedAsPermission() async {
  let harness = Harness(permissions: [[.granted], [.denied]])
  harness.controller.setEnabled(true)
  await harness.settle()
  harness.engines.othersPlaying = true
  await harness.drain { !harness.controller.isEnabled }

  #expect(harness.controller.revocation == .permissionDenied)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.allStopped)
}

@MainActor
@Test("空間化した音の出力が止まれば作り直し、戻ればそのままオン")
func stoppedOutputIsRebuilt() async {
  let harness = Harness(permissions: [[.granted]], flowing: true)
  harness.controller.setEnabled(true)
  await harness.settle()
  harness.engines.built[0].isOutputRunning = false
  await harness.drain { harness.engines.built.count == 2 }
  let rebuilt = harness.engines.built[1]
  await harness.drain { rebuilt.reads >= 30 }

  #expect(harness.controller.isEnabled)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.built[0].stopped)
}

@MainActor
@Test("作り直しても出力が止まったままなら取り消し、エンジンを止める（元の音を戻す）")
func outputThatStaysStoppedIsRevoked() async {
  let harness = Harness(permissions: [[.granted]], flowing: true)
  harness.controller.setEnabled(true)
  await harness.settle()
  harness.engines.outputRunning = false
  harness.engines.built[0].isOutputRunning = false
  await harness.drain { !harness.controller.isEnabled }

  #expect(harness.controller.revocation == .outputStopped)
  #expect(harness.engines.built.count == 2)
  #expect(harness.engines.allStopped)
}

// MARK: - 問い合わせの置き場所と時間

@MainActor
@Test("許可の問い合わせ（coreaudiod との同期の往復）は MainActor の外で行う")
func permissionProbeRunsOffTheMainActor() async {
  let harness = Harness(permissions: [[.granted]])
  harness.controller.setEnabled(true)
  await harness.settle()

  let script = harness.engines.built[0].script
  #expect(script.asked >= 1)
  #expect(!script.askedOnMain)
}

@MainActor
@Test("問い合わせが戻らなくても MainActor は止まらず、判定できないとして期限で取り消す")
func hungProbeCountsAsUnknown() async {
  // 問い合わせはテストが解放するまで戻らない。待つのは 20ms まで。戻らない間の
  // 問い合わせは積まずに「判定できない」とする。
  let hold = DispatchSemaphore(value: 0)
  let harness = Harness(
    permissions: [[.granted]],
    timing: Harness.fastTiming(questionTimeout: .milliseconds(20)),
    probeHold: hold
  )
  harness.controller.setEnabled(true)
  await harness.settle()

  // 問い合わせがまだ戻っていないうちに、確認は期限まで進んで終わっている。
  let script = harness.engines.built[0].script
  #expect(harness.controller.revocation == .noAudioDetected)
  #expect(script.asked == 1)
  #expect(script.answered == 0)
  hold.signal()
}

@MainActor
@Test("期限は時計で測った実際の経過で数える（名目の間隔ではない）")
func deadlineFollowsTheClock() async {
  // 時計は観測ごとに2秒進む。6秒の期限には3回目の観測で届く。
  let timing = CaptureSupervisor.Timing(
    confirmInterval: .milliseconds(1),
    confirmDeadline: .seconds(6),
    questionTimeout: .seconds(30)
  )
  let harness = Harness(permissions: [[.denied]], timing: timing, clockStep: .seconds(2))
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(harness.controller.revocation == .permissionDenied)
  #expect(harness.engines.built[0].script.asked == 3)
}

@MainActor
@Test("スリープ明けのように1回だけ大きく空いた観測は、期限を進めない")
func oneLongGapIsNotCounted() async {
  // 1回目の呼び出しは開始時。2回目（最初の観測）だけ1時間進む。期限（15ms）に届くのは、
  // その後の通常の観測15回目。
  let harness = Harness(permissions: [[.denied]], clockJump: (call: 2, by: .seconds(3_600)))
  harness.controller.setEnabled(true)
  await harness.settle()

  #expect(harness.controller.revocation == .permissionDenied)
  #expect(harness.engines.built[0].script.asked == 16)
}

@MainActor
@Test("問い合わせの最中にオフにされたら、戻ってきた答えは捨てる（勝手にオンへ戻らない）")
func answerArrivingAfterTurningOffIsDropped() async {
  // 許可ありの答えは、オフにした後でしか戻らない。捨てなければオンへ戻ってしまう。
  let hold = DispatchSemaphore(value: 0)
  let harness = Harness(permissions: [[.granted]], probeHold: hold)
  harness.controller.setEnabled(true)
  let engine = harness.engines.built[0]
  let supervision = harness.controller.supervision
  await harness.drain { engine.script.asked >= 1 }
  #expect(engine.script.asked == 1)
  harness.controller.setEnabled(false)
  hold.signal()
  // 答えが戻り、見張りがそれを受け取って終わるまで待つ。
  await supervision?.value

  #expect(engine.script.answered == 1)
  #expect(!harness.controller.isEnabled)
  #expect(!harness.controller.isStarting)
  #expect(harness.controller.errorMessage == nil)
  #expect(harness.engines.built.count == 1)
  #expect(engine.stopped)
}

// MARK: - 文言

@Test("許可なしの案内は、画面収録ではなく「システムオーディオ録音のみ」へ向ける")
func permissionGuidanceNamesSystemAudioRecordingOnly() {
  let message = CaptureSupervisor.Revocation.permissionDenied.message
  #expect(
    message.contains("システムオーディオ録音のみ") || message.contains("System Audio Recording Only")
  )
}

@Test("取り込めなくなったときの文言は、何が起きたかと次の手を言う")
func captureLostMessageSaysWhatHappened() {
  let message = CaptureSupervisor.Revocation.captureLost.message
  #expect(!message.isEmpty)
  #expect(message != CaptureSupervisor.Revocation.noAudioDetected.message)
}

@Test("出力が止まったときの文言は、取り込みや許可の話と取り違えない")
func outputStoppedMessageIsItsOwn() {
  let message = CaptureSupervisor.Revocation.outputStopped.message
  #expect(!message.isEmpty)
  #expect(message != CaptureSupervisor.Revocation.captureLost.message)
  #expect(!message.contains("許可"))
  #expect(!message.lowercased().contains("permission"))
}

@Test("音声を検出できないときの文言は、許可が無いと決めつけない")
func noAudioMessageDoesNotBlamePermission() {
  let message = CaptureSupervisor.Revocation.noAudioDetected.message
  #expect(!message.contains("許可"))
  #expect(!message.lowercased().contains("permission"))
  #expect(!message.lowercased().contains("allow"))
}
