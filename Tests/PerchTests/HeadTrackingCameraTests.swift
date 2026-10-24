import Foundation
import SpatialAudioKit
import Testing

@testable import Perch

// カメラの選択・保存・抜き差しを、フェイクの一覧とプロバイダで検証する。
// 選んだカメラは消さずに覚え、無い間は代わりで動き、戻ってきたら再び使う。
// どのカメラで開いたかはプロバイダの生成記録で見る。

private let builtIn = TestCameras.builtIn
private let webcam = TestCameras.webcam
private let otherWebcam = TestCameras.otherWebcam

/// 生成したプロバイダと、それを開いたカメラの記録。
@MainActor
private final class Launches {
  var cameras: [CameraDevice] = []
  var providers: [FakeHeadPoseProvider] = []
  /// このカメラ id で開くと start() が投げる。
  var startErrors: [String: any Error] = [:]
  /// このカメラ id の start() は、テストが放すまで返らない。
  var heldStarts: Set<String> = []
  /// プロバイダを作る瞬間に呼ばれる（開いている最中にカメラが消える、を作る）。
  var onLaunch: ((CameraDevice) -> Void)?

  var last: FakeHeadPoseProvider? { providers.last }
}

@MainActor
private struct CameraHarness {
  let catalog: FakeCameraCatalog
  let launches = Launches()
  let controller: HeadTrackingController
  let defaults: UserDefaults

  init(
    cameras: [CameraDevice],
    defaults: UserDefaults,
    stallTimeout: Duration = .seconds(6),
    startupTimeout: Duration = .seconds(15),
    watchdogInterval: Duration = .seconds(2),
    disconnectGrace: Duration = .milliseconds(20)
  ) {
    catalog = FakeCameraCatalog(cameras)
    self.defaults = defaults
    let launches = self.launches
    controller = HeadTrackingController(
      providerFactory: { camera in
        launches.onLaunch?(camera)
        let provider = FakeHeadPoseProvider(
          startError: launches.startErrors[camera.id],
          holdsStart: launches.heldStarts.contains(camera.id)
        )
        launches.cameras.append(camera)
        launches.providers.append(provider)
        return provider
      },
      cameraCatalog: catalog,
      authorization: { .authorized },
      requestAccess: { true },
      defaults: defaults,
      calibrationSamples: 3,
      calibrationMissLimit: 5,
      stallTimeout: stallTimeout,
      startupTimeout: startupTimeout,
      watchdogInterval: watchdogInterval,
      disconnectGrace: disconnectGrace
    )
  }

  func drain(until condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  /// 較正を済ませて追跡状態まで進める。
  func track(on provider: FakeHeadPoseProvider?) async {
    await drain { provider?.started == true }
    for index in 0..<4 {
      provider?.continuation.yield(face(index))
    }
    await drain { controller.status == .tracking }
  }

  func face(_ index: Int) -> HeadPoseSample {
    HeadPoseSample(
      time: Double(index) / 15,
      rotation: Rotation(yaw: 0.2, pitch: 0, roll: 0),
      pixelIPD: 60,
      faceWidth: 200
    )
  }

  var isFailed: Bool {
    if case .failed = controller.status { return true }
    return false
  }
}

/// テストごとに使い捨ての defaults。終わったら消して、実際の設定へ漏らさない。
@MainActor
private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
  let name = "HeadTrackingCameraTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  try await body(defaults)
}

private let cameraKey = "HeadTracking.camera"

// MARK: - 一覧の読み込み

@MainActor
@Test("起動時にはカメラを列挙しない。一覧は求められたときに読む")
func camerasAreNotListedAtLaunch() async {
  await withDefaults { defaults in
    // 最初の列挙は CoreMediaIO の読み込みで main を1秒近く止めうる。アプリ起動の
    // たびに — ヘッドトラッキングを使わない人にまで — 払わせない。
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    #expect(harness.catalog.enumerations == 0)
    #expect(harness.controller.cameras == nil)
    #expect(!harness.controller.isPreferredCameraMissing)

    await harness.controller.loadCameras()
    #expect(harness.controller.cameras == [builtIn, webcam])
    #expect(harness.catalog.enumerations == 1)
  }
}

@MainActor
@Test("欄を開き直すたびに読み直し、通知の出ない変化（蓋を開けて戻った内蔵カメラ）も拾う")
func lookingAgainRelistsCameras() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [webcam], defaults: defaults)
    await harness.controller.loadCameras()
    #expect(harness.controller.cameras == [webcam])

    harness.catalog.cameras = [builtIn, webcam]
    await harness.controller.loadCameras()
    #expect(harness.controller.cameras == [builtIn, webcam])
  }
}

@MainActor
@Test("裏の読み込み中に通知が一覧を埋めたら、遅れて届いた読み込み結果では上書きしない")
func aNoticeDuringTheFirstLoadWins() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    harness.catalog.holdsLoad = true
    let controller = harness.controller
    let load = Task { await controller.loadCameras() }
    await harness.drain { harness.catalog.isHoldingLoad }

    harness.catalog.send([builtIn, webcam])
    harness.catalog.releaseLoad(with: [builtIn])
    await load.value
    #expect(harness.controller.cameras == [builtIn, webcam])
  }
}

@MainActor
@Test("一覧を読む前にオンにしても、開く直前に列挙して正しいカメラで開く")
func enablingBeforeTheListLoadsStillChooses() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.drain { !harness.launches.cameras.isEmpty }
    #expect(harness.launches.cameras == [webcam])
    #expect(harness.controller.cameras == [builtIn, webcam])
  }
}

// MARK: - 選択と保存

@MainActor
@Test("選択が無ければ内蔵カメラで開く")
func opensTheBuiltInCameraByDefault() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [webcam, builtIn], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.drain { !harness.launches.cameras.isEmpty }
    #expect(harness.launches.cameras == [builtIn])
    #expect(harness.controller.activeCamera == builtIn)
  }
}

@MainActor
@Test("保存された選択のカメラで開く")
func opensTheSavedCamera() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    await harness.controller.loadCameras()
    #expect(harness.controller.preferredCameraID == "webcam")
    #expect(harness.controller.effectiveCamera == webcam)

    harness.controller.setEnabled(true)
    await harness.drain { !harness.launches.cameras.isEmpty }
    #expect(harness.launches.cameras == [webcam])
  }
}

@MainActor
@Test("選んだカメラは次の起動でも残る")
func theChoiceSurvivesARelaunch() async {
  await withDefaults { defaults in
    let first = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    await first.controller.loadCameras()
    first.controller.selectCamera(id: "webcam")
    #expect(first.controller.preferredCameraID == "webcam")

    let relaunched = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    await relaunched.controller.loadCameras()
    #expect(relaunched.controller.preferredCameraID == "webcam")
    #expect(relaunched.controller.effectiveCamera == webcam)
  }
}

@MainActor
@Test("一覧に無い id は選べない（保存もしない）")
func anUnknownCameraCannotBeChosen() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    await harness.controller.loadCameras()
    harness.controller.selectCamera(id: "nowhere")
    #expect(harness.controller.preferredCameraID == nil)
    #expect(defaults.string(forKey: cameraKey) == nil)
  }
}

@MainActor
@Test("保存されたカメラが未接続なら内蔵で開き、選択は消さずに残す")
func aMissingSavedCameraFallsBackButIsKept() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    await harness.controller.loadCameras()
    #expect(harness.controller.isPreferredCameraMissing)

    harness.controller.setEnabled(true)
    await harness.drain { !harness.launches.cameras.isEmpty }
    #expect(harness.launches.cameras == [builtIn])
    #expect(harness.controller.preferredCameraID == "webcam")
    #expect(defaults.string(forKey: cameraKey) == "webcam")
  }
}

@MainActor
@Test("選んだカメラが未接続のとき、使っている代わりを選び直せば、それが新しい選択になる")
func choosingTheFallbackReplacesAMissingPick() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    await harness.controller.loadCameras()
    #expect(harness.controller.effectiveCamera == builtIn)

    harness.controller.selectCamera(id: "builtin")
    #expect(harness.controller.preferredCameraID == "builtin")
    #expect(!harness.controller.isPreferredCameraMissing)
    #expect(defaults.string(forKey: cameraKey) == "builtin")
  }
}

@MainActor
@Test("カメラが1台も無ければ、カメラを開かずに failed")
func noCameraAtAllFailsWithoutOpeningOne() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [], defaults: defaults)
    harness.controller.setEnabled(true)
    #expect(harness.isFailed)
    #expect(harness.launches.cameras.isEmpty)
  }
}

// MARK: - 動作中の切り替え

@MainActor
@Test("動作中に選び直すと、前のカメラを止めて新しいカメラで較正からやり直す")
func choosingAnotherCameraWhileRunningSwitches() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)
    let first = harness.launches.last

    harness.controller.selectCamera(id: "webcam")
    #expect(harness.launches.cameras == [builtIn, webcam])
    #expect(first?.stopped == true)
    #expect(harness.controller.status == .calibrating)
    #expect(harness.controller.activeCamera == webcam)
    await harness.drain { harness.launches.last?.started == true }
    #expect(harness.launches.last?.started == true)
  }
}

@MainActor
@Test("停止中に選び直しても、カメラは開かない")
func choosingWhileOffOpensNothing() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    await harness.controller.loadCameras()
    harness.controller.selectCamera(id: "webcam")
    #expect(harness.controller.preferredCameraID == "webcam")
    #expect(harness.launches.cameras.isEmpty)
    #expect(harness.controller.status == .off)
  }
}

@MainActor
@Test("使用中のカメラが外れたら、代わりのカメラへ自動で切り替える")
func losingTheActiveCameraSwitchesToAnother() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)
    let unplugged = harness.launches.last

    harness.catalog.send([builtIn])
    #expect(harness.launches.cameras == [webcam, builtIn])
    #expect(unplugged?.stopped == true)
    #expect(harness.controller.status == .calibrating)
    #expect(harness.controller.cameras == [builtIn])
    // 選択は残す — 戻ってきたら再び使うため。
    #expect(harness.controller.preferredCameraID == "webcam")
  }
}

@MainActor
@Test("選んだカメラが再接続されたら、再びそれを使う")
func theChosenCameraIsUsedAgainOnReconnect() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)
    #expect(harness.launches.cameras == [builtIn])

    harness.catalog.send([builtIn, webcam])
    #expect(harness.launches.cameras == [builtIn, webcam])
    #expect(harness.controller.activeCamera == webcam)
    #expect(!harness.controller.isPreferredCameraMissing)
  }
}

@MainActor
@Test("使っていないカメラの抜き差しでは乗り換えない")
func unrelatedCamerasDoNotInterrupt() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    harness.catalog.send([builtIn, webcam])
    harness.catalog.send([builtIn, otherWebcam])
    #expect(harness.launches.cameras == [builtIn])
    #expect(harness.controller.status == .tracking)
  }
}

@MainActor
@Test("選択が無いまま代わりで動いているとき、別の外付けがつながっても飛ばない")
func aFallbackStaysPutWhenAnotherCameraArrives() async {
  await withDefaults { defaults in
    // 内蔵の無い Mac: 先頭の外付けで動いている。後からつながった外付けが検出順で
    // 前に来ても、使用中のカメラに留まる。
    let harness = CameraHarness(cameras: [webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    harness.catalog.send([otherWebcam, webcam])
    #expect(harness.launches.cameras == [webcam])
    #expect(harness.controller.status == .tracking)
  }
}

@MainActor
@Test("停止中の抜き差しは一覧を更新するだけで、カメラを開かない")
func changesWhileOffOnlyRefreshTheList() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    harness.catalog.send([builtIn, webcam])
    #expect(harness.controller.cameras == [builtIn, webcam])
    #expect(harness.launches.cameras.isEmpty)
    #expect(harness.controller.status == .off)
  }
}

@MainActor
@Test("最後のカメラが外れたら failed にしてカメラを止める")
func losingTheLastCameraFails() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    harness.catalog.send([])
    #expect(harness.isFailed)
    #expect(harness.launches.last?.stopped == true)
    #expect(harness.controller.activeCamera == nil)
  }
}

@MainActor
@Test("切断通知より先にストリームが終わっても、カメラが消えていれば代わりへ")
func aStreamEndFromAnUnpluggedCameraSwitches() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    // 列挙ではもう居ないが、切断通知はまだ届いていない。
    harness.catalog.cameras = [builtIn]
    harness.launches.last?.continuation.finish()
    await harness.drain { harness.launches.cameras.count == 2 }
    #expect(harness.launches.cameras == [webcam, builtIn])
    #expect(harness.controller.status == .calibrating)
  }
}

@MainActor
@Test("カメラが一覧に残ったままのストリーム終端は、従来どおり failed")
func aStreamEndFromAListedCameraStillFails() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    harness.launches.last?.continuation.finish()
    await harness.drain { harness.isFailed }
    #expect(harness.isFailed)
    #expect(harness.launches.cameras == [builtIn])
  }
}

@MainActor
@Test("開く途中でカメラが消えて cameraNotFound なら、代わりのカメラで開き直す")
func aCameraThatVanishesWhileOpeningIsReplaced() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.launches.startErrors["webcam"] = CameraHeadPoseProvider.ProviderError.cameraNotFound
    let catalog = harness.catalog
    harness.launches.onLaunch = { camera in
      if camera == webcam { catalog.cameras = [builtIn] }
    }

    harness.controller.setEnabled(true)
    await harness.drain { harness.launches.cameras.count == 2 }
    #expect(harness.launches.cameras == [webcam, builtIn])
    #expect(harness.controller.status == .calibrating)
  }
}

@MainActor
@Test("cameraNotFound で代わりも無ければ failed。生のエラー名は見せない")
func cameraNotFoundWithoutAReplacementFails() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [webcam], defaults: defaults)
    harness.launches.startErrors["webcam"] = CameraHeadPoseProvider.ProviderError.cameraNotFound

    harness.controller.setEnabled(true)
    await harness.drain { harness.isFailed }
    guard case .failed(let message) = harness.controller.status else {
      Issue.record("failed にならなかった: \(harness.controller.status)")
      return
    }
    #expect(!message.contains("cameraNotFound"))
    #expect(harness.launches.cameras == [webcam])
  }
}

// MARK: - 止まったカメラの見極め

@MainActor
@Test("終端の時点で列挙がまだ古くても、猶予内に届いた切断通知で代わりへ移る")
func aLateDisconnectNoticeStillSwitches() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(
      cameras: [builtIn, webcam], defaults: defaults, disconnectGrace: .seconds(5)
    )
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    // ストリームだけが先に終わる。列挙ではまだ居て、切断通知も来ていない。
    harness.launches.last?.continuation.finish()
    try? await Task.sleep(for: .milliseconds(50))
    // 猶予の間は、まだ失敗と決めつけない。
    #expect(!harness.isFailed)

    harness.catalog.send([builtIn])
    #expect(harness.launches.cameras == [webcam, builtIn])
    #expect(harness.controller.status == .calibrating)
  }
}

@MainActor
@Test("映像が途絶えた時点でカメラが一覧から消えていれば、失敗にせず代わりへ")
func aStallFromAnUnpluggedCameraSwitches() async {
  await withDefaults { defaults in
    defaults.set("webcam", forKey: cameraKey)
    let harness = CameraHarness(
      cameras: [builtIn, webcam],
      defaults: defaults,
      stallTimeout: .milliseconds(120),
      watchdogInterval: .milliseconds(30)
    )
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)

    // 終端も通知も無く、ただ黙った。列挙からは消えている。
    harness.catalog.cameras = [builtIn]
    await harness.drain { harness.launches.cameras.count == 2 }
    #expect(harness.launches.cameras == [webcam, builtIn])
    #expect(!harness.isFailed)
  }
}

@MainActor
@Test("開いている途中で選び直したら、前のカメラの開始失敗は無視する")
func aSupersededStartFailureIsIgnored() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.launches.heldStarts = ["builtin"]
    harness.launches.startErrors["builtin"] = CameraHeadPoseProvider.ProviderError.cameraNotFound
    harness.controller.setEnabled(true)
    let first = harness.launches.last
    await harness.drain { first?.isHoldingStart == true }

    harness.controller.selectCamera(id: "webcam")
    first?.releaseStart()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(harness.launches.cameras == [builtIn, webcam])
    #expect(harness.controller.activeCamera == webcam)
    #expect(harness.controller.status == .calibrating)
  }
}

@MainActor
@Test("開き始める前に乗り換えたカメラは、後から開き始めない")
func aCancelledLaunchNeverStartsTheCamera() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    harness.controller.setEnabled(true)
    // 開始のタスクが走り出す前に、同じ同期区間で乗り換える。
    harness.controller.selectCamera(id: "webcam")
    let first = harness.launches.providers.first
    await harness.drain { harness.launches.last?.started == true }
    #expect(harness.launches.cameras == [builtIn, webcam])
    #expect(first?.started == false)
  }
}

@MainActor
@Test("起動に時間のかかるカメラを、開き終わる前に「映像が届かない」と決めつけない")
func aSlowStartIsNotAStall() async {
  await withDefaults { defaults in
    // Continuity Camera（iPhone）は起動に数秒かかりうる。途絶の猶予は開き終わってから数える。
    let harness = CameraHarness(
      cameras: [builtIn],
      defaults: defaults,
      stallTimeout: .milliseconds(120),
      startupTimeout: .seconds(5),
      watchdogInterval: .milliseconds(30)
    )
    harness.launches.heldStarts = ["builtin"]
    harness.controller.setEnabled(true)
    let provider = harness.launches.last
    await harness.drain { provider?.isHoldingStart == true }

    try? await Task.sleep(for: .milliseconds(300))
    #expect(harness.controller.status == .calibrating)

    provider?.releaseStart()
    for index in 0..<4 {
      provider?.continuation.yield(harness.face(index))
    }
    await harness.drain { harness.controller.status == .tracking }
    #expect(harness.controller.status == .tracking)
  }
}

@MainActor
@Test("開き終わらないまま起動の猶予を過ぎたら failed")
func aStartThatNeverFinishesFails() async {
  await withDefaults { defaults in
    let harness = CameraHarness(
      cameras: [builtIn],
      defaults: defaults,
      stallTimeout: .milliseconds(60),
      startupTimeout: .milliseconds(150),
      watchdogInterval: .milliseconds(30)
    )
    harness.launches.heldStarts = ["builtin"]
    harness.controller.setEnabled(true)
    let provider = harness.launches.last
    await harness.drain { harness.isFailed }
    #expect(harness.isFailed)
    #expect(provider?.stopped == true)
    // 止めた後に放しても何も起きない（テストの後始末でもある）。
    provider?.releaseStart()
  }
}

/// applyPose へ届いた最後の向き。
@MainActor
private final class DeliveredPose {
  var last: ListenerOrientation?
}

@MainActor
@Test("後ろ向きの間にカメラを選び直したら、音場を正面へ戻し、後ろ向きを新しいカメラへ持ち越さない")
func switchingCamerasWhileFacingAwayStartsOver() async {
  await withDefaults { defaults in
    let harness = CameraHarness(cameras: [builtIn, webcam], defaults: defaults)
    let delivered = DeliveredPose()
    harness.controller.applyPose = { orientation, _ in delivered.last = orientation }
    harness.controller.setEnabled(true)
    await harness.track(on: harness.launches.last)
    let first = harness.launches.last
    for index in 4..<40 {
      first?.continuation.yield(.facingAway(time: Double(index) / 15))
    }
    await harness.drain {
      harness.controller.status == .facingAway && abs(abs(delivered.last?.yaw ?? 0) - .pi) < 1e-3
    }
    #expect(harness.controller.status == .facingAway)

    harness.controller.selectCamera(id: "webcam")
    #expect(first?.stopped == true)
    #expect(harness.controller.status == .calibrating)
    #expect(delivered.last == .forward)

    // 新しいカメラで較正が済めば、真後ろからではなく正面から追跡を始める。
    await harness.track(on: harness.launches.last)
    #expect(harness.controller.status == .tracking)
    #expect(abs(delivered.last?.yaw ?? .pi) < 1.0)
  }
}
