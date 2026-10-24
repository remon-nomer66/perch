import AVFoundation
import Foundation
import SpatialAudioKit
import os

/// カメラのヘッドトラッキングを共通シートから駆動する。
///
/// パイプラインは カメラ(Vision) → 較正(PoseCenter) → スムージング(RotationOneEuroFilter)
/// → ロスト受け皿(TrackingBlend) → 空間オーディオのリスナー向き。数学はすべて
/// SpatialAudioKit の純粋型で、ここはその結線と UI 状態だけを持つ。
///
/// カメラは完全オプトイン: トグル操作の後にだけ許可を求め、オフ・アプリ終了で必ず止める。
/// フレームはプロバイダの外に出ず、ここへ届くのは角度と信頼状態だけ。
///
/// カメラは内蔵・外付け・Continuity Camera から選べる。選択は保存して次回へ持ち越し、
/// 未接続の間も消さない — 代わりのカメラで動き、戻ってきたら再び使う。使用中の
/// カメラが外れたら代わりへ自動で乗り換える。どれを使うかは毎回
/// `CameraSelection.choose` に一覧・選択・使用中を渡して決める（判断はそこだけ）。
///
/// プロバイダ・カメラ一覧・権限は注入できる: 実カメラ無しで許可・較正・ロスト・失敗・
/// 抜き差しの状態遷移をテストするため（既定は実カメラ）。
@MainActor
final class HeadTrackingController: ObservableObject {
  private static let log = Logger(subsystem: "dev.perch.mac", category: "HeadTracking")

  enum Status: Equatable {
    case off
    /// カメラ許可ダイアログへの返事を待っている。
    case requestingPermission
    /// 有効化直後: いまの顔向きを「正面」として覚えている最中。
    case calibrating
    case tracking
    /// 顔を見失っている（暗所・横向き・離席）。音場はゆっくり正面へ戻る。
    case faceLost
    case denied
    case failed(String)
  }

  @Published private(set) var status: Status = .off

  /// 選べるカメラ（内蔵 → 外付け → Continuity Camera の順）。抜き差しのたびに更新する。
  /// nil はまだ一度も列挙していない — 最初の列挙は重い（CoreMediaIO の読み込みで
  /// 0.2〜1秒）ので起動時には読まず、カメラの欄が初めて出たとき `loadCameras` で裏で読む。
  @Published private(set) var cameras: [CameraDevice]?

  /// ユーザーが選んだカメラの uniqueID。起動をまたいで保持し、外されても消さない
  /// （再接続されたら黙ってそれへ戻るため）。未選択は nil。
  @Published private(set) var preferredCameraID: String?

  /// いまプロバイダが開いているカメラ。止まっている間は nil（＝動作中かどうかの印）。
  @Published private(set) var activeCamera: CameraDevice?

  /// 開いている、または次に開くカメラ。メニューのチェックと見出しの名前はこれを映す。
  var effectiveCamera: CameraDevice? {
    CameraSelection.choose(
      from: cameras ?? [], preferredID: preferredCameraID, currentID: activeCamera?.id
    )
  }

  /// 選んだカメラが未接続で、代わりを使っている（使うことになる）。一覧をまだ読んで
  /// いなければ分からないので false。
  var isPreferredCameraMissing: Bool {
    guard let preferredCameraID, let cameras else { return false }
    return !cameras.contains { $0.id == preferredCameraID }
  }

  /// 距離連動（実験的）。較正点からの相対距離を減衰とこもりに写す。
  /// オフでも測定は続く（較正だけは済ませておく）が、届ける比率は常に 1.0。
  @Published var distanceEnabled: Bool {
    didSet {
      defaults.set(distanceEnabled, forKey: Keys.distance)
    }
  }

  /// トグルの見た目。許可待ち・較正中・見失い中もオンとして扱う。
  var isEnabled: Bool {
    switch status {
    case .off, .denied, .failed: false
    case .requestingPermission, .calibrating, .tracking, .faceLost: true
    }
  }

  /// 追従したリスナーの姿勢の届け先（空間オーディオコントローラ）。
  /// (向き, 相対距離比 — 距離連動オフのときは常に 1.0)。
  var applyPose: ((ListenerOrientation, Double) -> Void)?

  private let providerFactory: @MainActor (CameraDevice) -> any HeadPoseProvider
  private let cameraCatalog: any CameraCatalog
  private let authorization: () -> AVAuthorizationStatus
  private let requestAccess: () async -> Bool
  private let defaults: UserDefaults

  private var provider: (any HeadPoseProvider)?
  private var pipeline: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var center: PoseCenter
  private var filter = RotationOneEuroFilter()
  private var blend = TrackingBlend()
  private var distance: RelativeDistanceEstimator?
  private var lastTime: Double?
  private var receivedAnySample = false
  /// 最後にフレームが届いた壁時計時刻（起動直後は起動時刻）。フレームの絶えた
  /// カメラ — 中断・他アプリの占有・黙ったままの構成成功 — を watchdog が見る。
  private var lastSampleAt = ContinuousClock.now
  /// 較正中に顔の取れないフレームが続いた数。閾値超えで「検出できない」と告げて止まる
  /// （黙って較正中のまま永久に待たない）。15fps で約8秒ぶん。
  private var calibrationMisses = 0
  private let calibrationMissLimit: Int
  private let calibrationSamples: Int
  private let stallTimeout: Duration
  /// 開き終わるまでの猶予。Continuity Camera（iPhone）は起動に数秒かかり、乗り換えでは
  /// 前のカメラの停止の後ろに並ぶ。その間を「映像が届かない」と数えない。
  private let startupTimeout: Duration
  private let watchdogInterval: Duration
  /// 止まったカメラが一覧に残っていたとき、失敗と決める前に待つ時間。外された直後は
  /// ストリームの終端が切断の通知より先に届き、列挙もまだ追いついていないことがある。
  private let disconnectGrace: Duration
  /// provider.start() がまだ返っていない。
  private var isCameraStarting = false
  /// 止まったカメラを猶予の後に見直す待ち。乗り換え・停止・失敗で取り消す。
  private var stopCheck: Task<Void, Never>?

  init(
    providerFactory: @escaping @MainActor (CameraDevice) -> any HeadPoseProvider = {
      CameraHeadPoseProvider(cameraID: $0.id)
    },
    cameraCatalog: any CameraCatalog = SystemCameraCatalog(),
    authorization: @escaping () -> AVAuthorizationStatus = { CameraHeadPoseProvider.authorization },
    requestAccess: @escaping () async -> Bool = { await CameraHeadPoseProvider.requestAccess() },
    defaults: UserDefaults = .standard,
    calibrationSamples: Int = 15,
    calibrationMissLimit: Int = 120,
    stallTimeout: Duration = .seconds(6),
    startupTimeout: Duration = .seconds(15),
    watchdogInterval: Duration = .seconds(2),
    disconnectGrace: Duration = .seconds(1)
  ) {
    self.providerFactory = providerFactory
    self.cameraCatalog = cameraCatalog
    self.authorization = authorization
    self.requestAccess = requestAccess
    self.defaults = defaults
    self.calibrationSamples = calibrationSamples
    self.calibrationMissLimit = calibrationMissLimit
    self.stallTimeout = stallTimeout
    self.startupTimeout = startupTimeout
    self.watchdogInterval = watchdogInterval
    self.disconnectGrace = disconnectGrace
    distanceEnabled = defaults.object(forKey: Keys.distance) as? Bool ?? false
    preferredCameraID = defaults.string(forKey: Keys.camera)
    center = PoseCenter(sampleTarget: calibrationSamples)
    cameraCatalog.onChange = { [weak self] cameras in
      self?.camerasChanged(cameras)
    }
  }

  func setEnabled(_ on: Bool) {
    if on {
      start()
    } else {
      stopTracking()
    }
  }

  /// いまの顔向きを新しい「正面」にする。較正をやり直すだけ。
  /// 追跡が確立した後にだけ意味がある — 許可待ちや較正中に呼ばれても何もしない
  /// （許可待ち中に状態を書き換えると、許可の返事が宙に浮く）。
  func recenter() {
    guard status == .tracking || status == .faceLost else { return }
    center = PoseCenter(sampleTarget: calibrationSamples)
    filter = RotationOneEuroFilter()
    distance = nil
    calibrationMisses = 0
    status = .calibrating
  }

  /// 使うカメラを選ぶ。保存して次回の起動にも持ち越す。動作中なら即座にそのカメラへ
  /// 移り、較正からやり直す（視点が変われば前の「正面」は意味を失う）。
  /// 一覧に無い id は受け付けない — 選べるのは、いま選べるものだけ。
  func selectCamera(id: String) {
    guard id != preferredCameraID, cameras?.contains(where: { $0.id == id }) == true else {
      return
    }
    preferredCameraID = id
    defaults.set(id, forKey: Keys.camera)
    followEffectiveCamera()
  }

  /// カメラの欄が表示されるたびに一覧を読み直す。重い最初の列挙はカタログが main の
  /// 外で済ませる。毎回読むのは、通知の出ない変化 — 蓋を開けて戻った内蔵カメラ
  /// （閉じている間は suspend で一覧から外している）— を拾うため。2回目以降は軽い。
  /// 最初の読み込みの間に、開く操作の同期の読み直しや抜き差しの通知が先に一覧を
  /// 埋めていれば、そちらの方が新しいので譲る。
  func loadCameras() async {
    let isFirstLook = cameras == nil
    let listed = await cameraCatalog.loadCameras()
    if isFirstLook {
      guard cameras == nil else { return }
      cameras = listed
    } else {
      camerasChanged(listed)
    }
  }

  private func camerasChanged(_ updated: [CameraDevice]) {
    guard updated != cameras else { return }
    cameras = updated
    followEffectiveCamera()
  }

  /// 動作中なら、一覧と選択がいま指すカメラへ移る。指す先が使用中と同じなら何もしない
  /// — 使っていないカメラの抜き差しで較正を捨てない。止まっている間は一覧を覚えるだけで、
  /// カメラは開かない（開くのはトグルの操作だけ）。
  private func followEffectiveCamera() {
    guard let active = activeCamera else { return }
    guard let next = effectiveCamera else {
      Self.log.info("The camera in use went away and no other camera is left")
      fail(Self.noCameraMessage)
      return
    }
    guard next.id != active.id else { return }
    switchCamera(to: next)
  }

  /// カメラが止まった（ストリームの終端・開けなかった・沈黙）。外されたせいなら —
  /// 切断の通知より先にこちらが届くことがある — 失敗にせず代わりへ移る。一覧に
  /// 残ったままなら、少しだけ待って見直す: 外された直後で列挙と通知がまだ追いついて
  /// いないだけかもしれない（その間に通知が来れば camerasChanged が乗り換え、teardown
  /// がこの見直しを取り消す）。それでも残っていれば本当の失敗（他アプリの占有など）
  /// なので告げる。
  private func cameraStopped(otherwise message: String) {
    // 見直しの最中に別の経路（終端の後の沈黙など）からもう一度来ても重ねない。
    guard stopCheck == nil else { return }
    refreshCameras()
    if isActiveCameraGone {
      moveOffActiveCamera()
      return
    }
    stopCheck = Task { @MainActor [weak self] in
      try? await Task.sleep(for: self?.disconnectGrace ?? .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.stopCheck = nil
      self.refreshCameras()
      if self.isActiveCameraGone {
        self.moveOffActiveCamera()
      } else {
        self.fail(message)
      }
    }
  }

  /// 使用中のカメラが、いまの一覧から消えている。
  private var isActiveCameraGone: Bool {
    guard let active = activeCamera, let cameras else { return false }
    return !cameras.contains { $0.id == active.id }
  }

  private func moveOffActiveCamera() {
    if let next = effectiveCamera {
      switchCamera(to: next)
    } else {
      fail(Self.noCameraMessage)
    }
  }

  private func switchCamera(to camera: CameraDevice) {
    // 名前と uniqueID は書かない（iPhone の名前は持ち主の名前を含む）。種類だけ。
    Self.log.info(
      "Switching the head-tracking camera to a \(String(describing: camera.kind), privacy: .public) camera"
    )
    teardown()
    // 前のカメラで追った向きを新しい視点へ持ち越さない。較正が済むまで音場は正面。
    applyPose?(.forward, 1.0)
    launch(on: camera)
  }

  /// 抜き差しの通知を待たずに、いまの一覧を読み直す。開く直前と、カメラが止まった
  /// 直後 — 判断が「いま何がつながっているか」に懸かる瞬間 — に使う。
  private func refreshCameras() {
    let fresh = cameraCatalog.currentCameras()
    if fresh != cameras {
      cameras = fresh
    }
  }

  private static var noCameraMessage: String {
    L("カメラが見つかりません。接続を確認してください。", "No camera found. Check that one is connected.")
  }

  private func start() {
    switch status {
    case .off, .denied, .failed: break
    default: return
    }
    switch authorization() {
    case .authorized:
      launch()
    case .notDetermined:
      status = .requestingPermission
      Task { @MainActor [weak self] in
        guard let self else { return }
        let granted = await self.requestAccess()
        guard self.status == .requestingPermission else { return }
        if granted {
          self.launch()
        } else {
          self.status = .denied
        }
      }
    case .restricted:
      status = .failed(
        L(
          "カメラの使用がシステム管理者により制限されています。",
          "Camera use is restricted by a system policy."
        )
      )
    default:
      status = .denied
    }
  }

  private func launch() {
    // 許可の返事を待つ間にも抜き差しはある。開く直前の一覧で決める。
    refreshCameras()
    guard let camera = effectiveCamera else {
      fail(Self.noCameraMessage)
      return
    }
    if isPreferredCameraMissing {
      Self.log.info("The chosen camera is not connected; starting with another one")
    }
    launch(on: camera)
  }

  private func launch(on camera: CameraDevice) {
    let provider = providerFactory(camera)
    self.provider = provider
    activeCamera = camera
    center = PoseCenter(sampleTarget: calibrationSamples)
    filter = RotationOneEuroFilter()
    blend = TrackingBlend()
    distance = nil
    lastTime = nil
    receivedAnySample = false
    calibrationMisses = 0
    isCameraStarting = true
    status = .calibrating

    pipeline = Task { @MainActor [weak self] in
      // タスクの本体は作った同期区間の後で走る。その間に乗り換え・停止で取り消されて
      // いたら開かない — stop() の後に start() が並び、外したはずのカメラが点く。
      guard !Task.isCancelled else { return }
      do {
        try await provider.start()
      } catch CameraHeadPoseProvider.ProviderError.cameraNotFound {
        // 一覧を作ってから開くまでの間に外された。代わりがあればそれで開き直す。
        guard let self, !Task.isCancelled else { return }
        self.cameraStopped(otherwise: Self.noCameraMessage)
        return
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.fail(
          L("カメラを開始できませんでした。", "Could not start the camera.") + " [\(error)]"
        )
        return
      }
      guard !Task.isCancelled else { return }
      self?.cameraDidStart()
      for await sample in provider.samples {
        guard let self, !Task.isCancelled else { return }
        self.process(sample)
      }
      // ストリームの終端は「カメラが止まった」の合図。自分で止めた（キャンセル済み）
      // のでなければ、追跡中の顔で UI が「使用中」を騙らないよう失敗へ落とす —
      // ただしカメラが外されたせいなら、代わりのカメラへ移る。
      guard let self, !Task.isCancelled, self.isEnabled else { return }
      self.cameraStopped(
        otherwise: L(
          "カメラが停止しました。もう一度オンにしてください。", "The camera stopped. Turn it on again."
        )
      )
    }

    // カメラの沈黙を較正・追跡表示のまま放置しない。最初の1枚が来ない（構成は
    // 成功したがカメラが黙っている）だけでなく、追跡確立後の停止 — 他アプリの
    // 占有・セッション中断はストリーム終端にならないことがある — も同じ看板で捕まえる。
    // 追跡表示のまま姿勢が固まると、音場が古い頭の向きに置き去りになる。
    lastSampleAt = .now
    watchdog = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.watchdogInterval ?? .seconds(2))
        guard let self, !Task.isCancelled else { return }
        // 許可待ちを数えない心配は要らない: watchdog は launch()（許可が下りた後）
        // でしか生まれず、走っている間に許可待ちへ戻る遷移は無い。
        guard self.isEnabled else { continue }
        let allowance = self.isCameraStarting ? self.startupTimeout : self.stallTimeout
        if ContinuousClock.now - self.lastSampleAt > allowance {
          // 外されたカメラが黙ったまま（終端も通知も無し）でも、ここで代わりへ移れる。
          self.cameraStopped(
            otherwise: self.receivedAnySample
              ? L(
                "カメラからの映像が止まりました。もう一度オンにしてください。",
                "Video from the camera stopped. Turn it on again."
              )
              : L("カメラから映像が届きません。", "No video is arriving from the camera.")
          )
          return
        }
      }
    }
  }

  /// カメラが開き終わった。途絶の猶予はここから数え直す — 起動にかかった時間を
  /// 「映像が届かない」に算入しない。
  private func cameraDidStart() {
    isCameraStarting = false
    lastSampleAt = .now
  }

  private func process(_ sample: HeadPoseSample) {
    receivedAnySample = true
    lastSampleAt = .now
    // フレーム時刻の差から dt を得る。中断（スリープ等）明けの巨大な dt は上限で抑える。
    let dt = lastTime.map { max(0.001, min(0.25, sample.time - $0)) } ?? 1.0 / 15
    lastTime = sample.time

    guard center.phase == .ready else {
      if let rotation = sample.rotation {
        calibrationMisses = 0
        if center.add(rotation: rotation, pixelIPD: sample.pixelIPD) == .ready {
          // 較正中に瞳が一度も取れなければ基準が無い — 距離連動は静かに諦め、
          // 向きの追従だけで動く。
          distance = center.referenceIPD.map { RelativeDistanceEstimator(referenceIPD: $0) }
          status = .tracking
        }
      } else {
        // 較正中のロストは待つ — ただし永久には待たない。
        calibrationMisses += 1
        if calibrationMisses >= calibrationMissLimit {
          fail(
            L(
              "顔を検出できません。明るさとカメラの向きを確認してください。",
              "No face detected. Check the lighting and the camera's view."
            )
          )
        }
      }
      return
    }

    let tracked = sample.rotation.map { filter.filter(center.centered($0), dt: dt) }

    // 距離: 測定は較正基準がある限り続け（トグルの切り替えで基準がずれない）、
    // 届けるかどうかだけをトグルが決める。yaw ゲートはカメラに対する生の向きで判く。
    var measuredRatio = 1.0
    if var estimator = distance, let rotation = sample.rotation {
      measuredRatio = estimator.update(
        pixelIPD: sample.pixelIPD,
        faceWidth: sample.faceWidth,
        yaw: rotation.eulerAngles.yaw
      )
      distance = estimator
    }
    let ratioForBlend = distanceEnabled ? measuredRatio : 1.0

    let (output, blendedRatio) = blend.advance(
      tracked: tracked,
      distanceRatio: tracked == nil ? nil : ratioForBlend,
      dt: dt
    )
    let nextStatus: Status = tracked == nil ? .faceLost : .tracking
    if status != nextStatus {
      status = nextStatus
    }
    applyPose?(output.listenerOrientation, blendedRatio)
  }

  /// 中断して理由を告げる。カメラは必ず止める（「使用中」の表示とランプを残さない）。
  private func fail(_ message: String) {
    teardown()
    status = .failed(message)
    applyPose?(.forward, 1.0)
  }

  private func stopTracking() {
    teardown()
    status = .off
    // 追従の置き土産を残さない: 音場は正面・較正距離へ戻す。
    applyPose?(.forward, 1.0)
  }

  /// カメラと付随タスクを片付ける。停止・失敗・カメラの乗り換えの共通部分で、
  /// 状態と音場をどうするかは呼び出し側が決める。
  private func teardown() {
    pipeline?.cancel()
    pipeline = nil
    watchdog?.cancel()
    watchdog = nil
    stopCheck?.cancel()
    stopCheck = nil
    isCameraStarting = false
    provider?.stop()
    provider = nil
    activeCamera = nil
    lastTime = nil
  }

  private enum Keys {
    static let distance = "HeadTracking.distance"
    static let camera = "HeadTracking.camera"
  }
}
