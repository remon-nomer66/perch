import AVFoundation
import SpatialAudioKit
import Testing

@testable import Perch

// コントローラの状態遷移を、実カメラ無しのフェイクプロバイダで検証する。
// 許可 → 較正 → 追跡 → 見失い/失敗/停止 の各辺と、recenter のガード。

/// テストから手で観測を流し込めるプロバイダ。
private final class FakeHeadPoseProvider: HeadPoseProvider, @unchecked Sendable {
  let samples: AsyncStream<HeadPoseSample>
  let continuation: AsyncStream<HeadPoseSample>.Continuation
  private(set) var started = false
  private(set) var stopped = false

  init() {
    // 実物は最新値のみ保持だが、テストは流した観測を全部処理してほしいので無制限。
    (samples, continuation) = AsyncStream.makeStream(of: HeadPoseSample.self)
  }

  func start() async throws {
    started = true
  }

  func stop() {
    stopped = true
    continuation.finish()
  }
}

@MainActor
private struct Harness {
  let provider = FakeHeadPoseProvider()
  let controller: HeadTrackingController
  /// applyPose へ届いた最後の姿勢。
  final class Delivered {
    var last: ListenerOrientation?
    var lastRatio: Double?
  }
  let delivered = Delivered()

  init(authorization: AVAuthorizationStatus = .authorized) {
    let provider = self.provider
    let defaults = UserDefaults(suiteName: "HeadTrackingControllerTests-\(UUID().uuidString)")!
    controller = HeadTrackingController(
      providerFactory: { provider },
      authorization: { authorization },
      requestAccess: { false },
      defaults: defaults,
      calibrationSamples: 3,
      calibrationMissLimit: 5
    )
    let delivered = self.delivered
    controller.applyPose = { orientation, ratio in
      delivered.last = orientation
      delivered.lastRatio = ratio
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
