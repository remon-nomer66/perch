import Foundation
import SpatialAudioKit
import Testing

@testable import Perch

// コントローラの流れを、フェイクのエンジンで確かめる。実際のプロセスタップは作らない
// （作るとシステムオーディオ録音の許可ダイアログが出てしまう）。判断そのものは
// CaptureSupervisorTests の表にあり、ここではそれが結線どおりに効くことを見る:
// エンジンを作る・止める・作り直す、オン/取り消しの状態と理由、オンの間の見張り。

/// テストから許可の判定と信号を台本どおりに返すエンジン。
@MainActor
private final class FakeEngine: SpatialCaptureEngine {
  /// 問い合わせごとに順に返す許可の判定。尽きたら最後のものを返し続ける。
  private let permissions: [SystemAudioPermission]
  private(set) var probes = 0
  private(set) var stopped = false
  /// 音が流れているか。流れている間は、読まれるたびに音のあるブロックが1つ増える。
  var flowing: Bool
  private var audibleBlocks = 0
  /// 見張りが信号を見た回数（1回の観測で1回読む）。時間の代わりに数える。
  private(set) var reads = 0
  private(set) var listener: ListenerOrientation?
  let estimatedBPM: Double? = nil

  init(permissions: [SystemAudioPermission], flowing: Bool) {
    self.permissions = permissions
    self.flowing = flowing
  }

  var audibleBlockCount: Int {
    reads += 1
    if flowing { audibleBlocks += 1 }
    return audibleBlocks
  }

  func probeCapturePermission() -> SystemAudioPermission {
    defer { probes += 1 }
    return permissions[min(probes, permissions.count - 1)]
  }

  func updateListener(_ orientation: ListenerOrientation) { listener = orientation }
  func setListenerDistance(ratio: Double) {}
  func stop() { stopped = true }
}

private struct StartFailure: Error {}

@MainActor
private struct Harness {
  /// 作ったエンジンの記録と、次に作るエンジンの台本。
  @MainActor
  final class Engines {
    var built: [FakeEngine] = []
    /// n 個目に作るエンジンの許可の台本。尽きたら最後のものを使う。
    var scripts: [[SystemAudioPermission]]
    /// 新しく作るエンジンで音が流れているか。
    var flowing: Bool
    var failToStart = false
    /// 他のプロセスが音を出しているか（AudibleProcesses の代わり）。
    var othersPlaying: Bool? = false

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
    timing: CaptureSupervisor.Timing = Harness.fastTiming
  ) {
    let engines = Engines(scripts: permissions, flowing: flowing)
    self.engines = engines
    let defaults = UserDefaults(suiteName: "SpatialAudioControllerTests-\(UUID().uuidString)")!
    controller = SpatialAudioController(
      defaults: defaults,
      makeEngine: { _, _ in
        if engines.failToStart { throw StartFailure() }
        let script = engines.scripts[min(engines.built.count, engines.scripts.count - 1)]
        let engine = FakeEngine(permissions: script, flowing: engines.flowing)
        engines.built.append(engine)
        return engine
      },
      othersPlaying: { engines.othersPlaying },
      timing: timing
    )
  }

  /// 時間の進みは観測の回数で数える（実時間ではない）ので、刻みを詰めても判断は変わらない。
  /// 見張りは5回続けて無音なら手を打つ。
  static let fastTiming = CaptureSupervisor.Timing(
    confirmInterval: .milliseconds(1),
    confirmDeadline: .milliseconds(15),
    watchInterval: .milliseconds(1),
    stallTimeout: .milliseconds(5)
  )

  /// 監視タスク（MainActor 上の別タスク）に回す。条件が満ちるまで譲る。
  func drain(until condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
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

@Test("音声を検出できないときの文言は、許可が無いと決めつけない")
func noAudioMessageDoesNotBlamePermission() {
  let message = CaptureSupervisor.Revocation.noAudioDetected.message
  #expect(!message.contains("許可"))
  #expect(!message.lowercased().contains("permission"))
  #expect(!message.lowercased().contains("allow"))
}
