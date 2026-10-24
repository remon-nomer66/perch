import AVFoundation
import SpatialAudioKit
import Testing

@testable import Perch

// コントローラの状態遷移を、実カメラ無しのフェイクプロバイダで検証する。
// 許可 → 較正 → 追跡 → 見失い/後ろ向き/失敗/停止 の各辺と、recenter のガード。
// カメラの選択と抜き差しは HeadTrackingCameraTests にある。

@MainActor
private struct Harness {
  let provider = FakeHeadPoseProvider()
  let controller: HeadTrackingController
  /// applyPose へ届いた最後の姿勢。
  final class Delivered {
    var last: ListenerOrientation?
    var lastRatio: Double?
    /// 届いた回数。較正中のフレームは届かないので、追跡確立後のフレーム数になる。
    var count = 0
  }
  let delivered = Delivered()

  init(
    authorization: AVAuthorizationStatus = .authorized,
    stallTimeout: Duration = .seconds(6),
    watchdogInterval: Duration = .seconds(2)
  ) {
    let provider = self.provider
    let defaults = UserDefaults(suiteName: "HeadTrackingControllerTests-\(UUID().uuidString)")!
    controller = HeadTrackingController(
      providerFactory: { _ in provider },
      cameraCatalog: FakeCameraCatalog([TestCameras.builtIn]),
      authorization: { authorization },
      requestAccess: { false },
      defaults: defaults,
      calibrationSamples: 3,
      calibrationMissLimit: 5,
      stallTimeout: stallTimeout,
      watchdogInterval: watchdogInterval,
      // 止まったカメラが「外されただけ」か見極める猶予。ここでは待たせない。
      disconnectGrace: .milliseconds(20)
    )
    let delivered = self.delivered
    controller.applyPose = { orientation, ratio in
      delivered.last = orientation
      delivered.lastRatio = ratio
      delivered.count += 1
    }
  }

  /// パイプライン（MainActor 上の別タスク）に回す。条件が満ちるまで譲る。
  func drain(until condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  func face(_ index: Int, yaw: Double = 0.2, pixelIPD: Double = 60) -> HeadPoseSample {
    HeadPoseSample(
      time: Double(index) / 15,
      rotation: Rotation(yaw: yaw, pitch: 0, roll: 0),
      pixelIPD: pixelIPD,
      faceWidth: pixelIPD * 3.3
    )
  }

  func lost(_ index: Int) -> HeadPoseSample {
    HeadPoseSample(time: Double(index) / 15, rotation: nil, pixelIPD: nil, faceWidth: nil)
  }

  /// 顔は見えず、背を向けた人が写っているフレーム。
  func away(_ index: Int) -> HeadPoseSample {
    .facingAway(time: Double(index) / 15)
  }

  /// 較正（3枚）を済ませ、追跡のフレームを1枚届けたところまで進める。
  func track(yaw: Double = 0.2) async {
    controller.setEnabled(true)
    await drain { provider.started }
    for index in 0..<4 {
      provider.continuation.yield(face(index, yaw: yaw))
    }
    await drain { controller.status == .tracking && delivered.count == 1 }
  }

  /// 真後ろ（yaw ±180°、pitch・roll 0）が届いている。
  var isBehind: Bool {
    guard let last = delivered.last else { return false }
    return abs(abs(last.yaw) - .pi) < 1e-3 && abs(last.pitch) < 1e-6 && abs(last.roll) < 1e-6
  }
}

@MainActor
@Test("有効化 → 較正 → 規定サンプルで追跡へ。向きが届く")
func calibratesThenTracks() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  #expect(harness.controller.status == .calibrating)

  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }
  #expect(harness.controller.status == .tracking)
  await harness.drain { harness.delivered.last != nil }
  #expect(harness.delivered.last != nil)
}

@MainActor
@Test("追跡確立後のロストは faceLost。向きは配られ続ける（中立へ向かう）")
func lostFaceIsReported() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  harness.provider.continuation.yield(harness.lost(4))
  await harness.drain { harness.controller.status == .faceLost }
  #expect(harness.controller.status == .faceLost)
}

@MainActor
@Test("許可が拒否されていれば denied で、カメラは開始されない")
func deniedNeverStartsTheCamera() async {
  let harness = Harness(authorization: .denied)
  harness.controller.setEnabled(true)
  await harness.drain { harness.controller.status == .denied }
  #expect(harness.controller.status == .denied)
  #expect(!harness.provider.started)
}

@MainActor
@Test("ストリームの終端（カメラの異常終了）は failed になり、カメラを確実に止める")
func streamEndBecomesFailure() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  harness.provider.continuation.finish()
  await harness.drain {
    if case .failed = harness.controller.status { return true }
    return false
  }
  guard case .failed = harness.controller.status else {
    Issue.record("failed にならなかった: \(harness.controller.status)")
    return
  }
  #expect(harness.provider.stopped)
}

@MainActor
@Test("較正中に顔が出ないまま上限に達したら、黙って待ち続けず failed")
func calibrationTimesOutWithoutAFace() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<6 {
    harness.provider.continuation.yield(harness.lost(index))
  }
  await harness.drain {
    if case .failed = harness.controller.status { return true }
    return false
  }
  guard case .failed = harness.controller.status else {
    Issue.record("failed にならなかった: \(harness.controller.status)")
    return
  }
  #expect(harness.provider.stopped)
}

@MainActor
@Test("オフでカメラが止まり、音場は正面へ戻る")
func disableStopsAndRecenters() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index, yaw: 0.4))
  }
  await harness.drain { harness.controller.status == .tracking }

  harness.controller.setEnabled(false)
  #expect(harness.controller.status == .off)
  #expect(harness.provider.stopped)
  #expect(harness.delivered.last == .forward)
  #expect(harness.delivered.lastRatio == 1.0)
}

@MainActor
@Test("距離連動オン: 瞳の間隔が半分になると距離比が 1 を超えて届く")
func distanceRatioFlowsWhenEnabled() async {
  let harness = Harness()
  harness.controller.distanceEnabled = true
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  // 較正は IPD 60px。
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  // 離席方向: 以後は 30px（距離2倍相当）。平滑化があるので数フレーム流す。
  for index in 4..<30 {
    harness.provider.continuation.yield(harness.face(index, pixelIPD: 30))
  }
  await harness.drain { (harness.delivered.lastRatio ?? 1) > 1.5 }
  #expect((harness.delivered.lastRatio ?? 1) > 1.5)
}

@MainActor
@Test("距離連動オフ: 瞳の間隔が変わっても届く比率は 1.0 のまま")
func distanceStaysNeutralWhenDisabled() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  for index in 4..<30 {
    harness.provider.continuation.yield(harness.face(index, pixelIPD: 30))
  }
  await harness.drain { harness.delivered.lastRatio != nil }
  #expect(harness.delivered.lastRatio == 1.0)
}

@MainActor
@Test("追跡確立後にフレームが絶えたら、追跡表示のまま固まらず failed へ")
func aStalledCameraDoesNotStayTracking() async {
  // ストリーム終端にならない停止 — 他アプリの占有・セッション中断 — では、最後の
  // 頭の向きに音場が置き去りになる。watchdog が沈黙を検知して看板を降ろすこと。
  let harness = Harness(stallTimeout: .milliseconds(120), watchdogInterval: .milliseconds(30))
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }
  #expect(harness.controller.status == .tracking)

  // 以後フレームを一切流さない（finish はしない — 終端検知とは別経路の検証）。
  await harness.drain {
    if case .failed = harness.controller.status { return true }
    return false
  }
  guard case .failed = harness.controller.status else {
    Issue.record("failed にならなかった: \(harness.controller.status)")
    return
  }
  #expect(harness.provider.stopped)
}

@MainActor
@Test("フレームが流れ続けている間は watchdog は黙っている")
func aLiveCameraIsLeftAlone() async {
  let harness = Harness(stallTimeout: .milliseconds(150), watchdogInterval: .milliseconds(30))
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  // stallTimeout より短い間隔で流し続ける。合計は timeout を大きく超える時間。
  for index in 4..<12 {
    harness.provider.continuation.yield(harness.face(index))
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(harness.controller.status == .tracking)
}

@MainActor
@Test("recenter は追跡確立後だけ効く（較正中は何もしない）")
func recenterOnlyAfterTracking() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  #expect(harness.controller.status == .calibrating)

  // 較正中は無視される。
  harness.controller.recenter()
  #expect(harness.controller.status == .calibrating)

  for index in 0..<4 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }

  // 追跡中は較正をやり直す。
  harness.controller.recenter()
  #expect(harness.controller.status == .calibrating)
}

// MARK: - 後ろ向き

@MainActor
@Test("追跡確立後、後ろ向きが続けば facingAway になり、音場は真後ろへ回る")
func facingAwayTurnsTheFieldBehind() async {
  let harness = Harness()
  await harness.track()

  // 0.4 秒待ってから 0.8 秒で回る。2.4 秒ぶん流す。
  for index in 4..<40 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain { harness.delivered.count == 37 }
  #expect(harness.controller.status == .facingAway)
  #expect(harness.isBehind)
  // トグルはオンのまま（カメラは動いている）。
  #expect(harness.controller.isEnabled)
}

@MainActor
@Test("後ろ向きが切り替えの待ちより短ければ、faceLost のまま")
func briefFacingAwayStaysLost() async {
  let harness = Harness()
  await harness.track()

  for index in 4..<8 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain { harness.delivered.count == 5 }
  #expect(harness.controller.status == .faceLost)
}

@MainActor
@Test("後ろ向きから顔が戻ったら、即座に tracking へ戻る")
func faceReturnEndsFacingAway() async {
  let harness = Harness()
  await harness.track()
  for index in 4..<20 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain { harness.controller.status == .facingAway }
  #expect(harness.controller.status == .facingAway)

  harness.provider.continuation.yield(harness.face(20))
  await harness.drain { harness.controller.status == .tracking }
  #expect(harness.controller.status == .tracking)
}

@MainActor
@Test("誰も写っていない（判定不能）なら従来どおり faceLost で、音場は正面へ戻る")
func nobodyInViewFadesToFront() async {
  let harness = Harness()
  await harness.track()
  // 較正の正面から 0.5 rad 振った向きを追わせておく。
  for index in 4..<20 {
    harness.provider.continuation.yield(harness.face(index, yaw: 0.7))
  }
  await harness.drain { harness.delivered.count == 17 }
  #expect(abs(harness.delivered.last?.yaw ?? 0) > 0.2)

  for index in 20..<65 {
    harness.provider.continuation.yield(harness.lost(index))
  }
  await harness.drain { harness.delivered.count == 62 }
  #expect(harness.controller.status == .faceLost)
  #expect(abs(harness.delivered.last?.yaw ?? 1) < 1e-6)
}

@MainActor
@Test("較正中は後ろ向きと判定しない — 顔を待ち、来なければ従来どおり failed")
func facingAwayDuringCalibrationWaitsForAFace() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<6 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain {
    if case .failed = harness.controller.status { return true }
    return false
  }
  guard case .failed = harness.controller.status else {
    Issue.record("failed にならなかった: \(harness.controller.status)")
    return
  }
  // 正面の基準が無いまま音場を回さない。届いたのは失敗時の「正面へ戻す」1回だけ。
  #expect(harness.delivered.count == 1)
  #expect(harness.delivered.last == .forward)
}

@MainActor
@Test("較正中の後ろ向きのフレームは見逃しとして数えるだけで、顔が来れば較正は進む")
func calibrationContinuesAfterFacingAwayFrames() async {
  let harness = Harness()
  harness.controller.setEnabled(true)
  await harness.drain { harness.provider.started }
  for index in 0..<3 {
    harness.provider.continuation.yield(harness.away(index))
  }
  for index in 3..<7 {
    harness.provider.continuation.yield(harness.face(index))
  }
  await harness.drain { harness.controller.status == .tracking }
  #expect(harness.controller.status == .tracking)
}

@MainActor
@Test("後ろ向きの間もフレームは届いているので、watchdog は failed にしない")
func facingAwayIsNotAStall() async {
  let harness = Harness(stallTimeout: .milliseconds(150), watchdogInterval: .milliseconds(30))
  await harness.track()

  // stallTimeout より短い間隔で後ろ向きのフレームを流し続ける。合計は timeout を大きく超える。
  for index in 4..<16 {
    harness.provider.continuation.yield(harness.away(index))
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(harness.controller.status == .facingAway)
  #expect(!harness.provider.stopped)
}

@MainActor
@Test("後ろ向きの間の recenter は何もしない（正面にする顔の向きが無い）")
func recenterIsIgnoredWhileFacingAway() async {
  let harness = Harness()
  await harness.track()
  for index in 4..<20 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain { harness.controller.status == .facingAway }

  harness.controller.recenter()
  #expect(harness.controller.status == .facingAway)
}

@MainActor
@Test("後ろ向きの間にストリームが終わっても、従来どおり failed でカメラを止め、音場を正面へ戻す")
func streamEndWhileFacingAwayFails() async {
  let harness = Harness()
  await harness.track()
  for index in 4..<40 {
    harness.provider.continuation.yield(harness.away(index))
  }
  await harness.drain { harness.controller.status == .facingAway && harness.isBehind }
  #expect(harness.isBehind)

  harness.provider.continuation.finish()
  await harness.drain {
    if case .failed = harness.controller.status { return true }
    return false
  }
  guard case .failed = harness.controller.status else {
    Issue.record("failed にならなかった: \(harness.controller.status)")
    return
  }
  #expect(harness.provider.stopped)
  #expect(harness.delivered.last == .forward)
}
