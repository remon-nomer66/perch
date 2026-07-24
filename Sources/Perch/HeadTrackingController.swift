import AVFoundation
import Foundation
import SpatialAudioKit

/// カメラのヘッドトラッキングを共通シートから駆動する。
///
/// パイプラインは カメラ(Vision) → 較正(PoseCenter) → スムージング(RotationOneEuroFilter)
/// → ロスト受け皿(TrackingBlend) → 空間オーディオのリスナー向き。数学はすべて
/// SpatialAudioKit の純粋型で、ここはその結線と UI 状態だけを持つ。
///
/// カメラは完全オプトイン: トグル操作の後にだけ許可を求め、オフ・アプリ終了で必ず止める。
/// フレームはプロバイダの外に出ず、ここへ届くのは角度と信頼状態だけ。
///
/// プロバイダ・権限は注入できる: 実カメラ無しで許可・較正・ロスト・失敗の状態遷移を
/// テストするため（既定は実カメラ）。
@MainActor
final class HeadTrackingController: ObservableObject {
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

  private let providerFactory: @MainActor () -> any HeadPoseProvider
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
  /// 較正中に顔の取れないフレームが続いた数。閾値超えで「検出できない」と告げて止まる
  /// （黙って較正中のまま永久に待たない）。15fps で約8秒ぶん。
  private var calibrationMisses = 0
  private let calibrationMissLimit: Int
  private let calibrationSamples: Int

  init(
    providerFactory: @escaping @MainActor () -> any HeadPoseProvider = { CameraHeadPoseProvider() },
    authorization: @escaping () -> AVAuthorizationStatus = { CameraHeadPoseProvider.authorization },
    requestAccess: @escaping () async -> Bool = { await CameraHeadPoseProvider.requestAccess() },
    defaults: UserDefaults = .standard,
    calibrationSamples: Int = 15,
    calibrationMissLimit: Int = 120
  ) {
    self.providerFactory = providerFactory
    self.authorization = authorization
    self.requestAccess = requestAccess
    self.defaults = defaults
    self.calibrationSamples = calibrationSamples
    self.calibrationMissLimit = calibrationMissLimit
    distanceEnabled = defaults.object(forKey: Keys.distance) as? Bool ?? false
    center = PoseCenter(sampleTarget: calibrationSamples)
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
    let provider = providerFactory()
    self.provider = provider
    center = PoseCenter(sampleTarget: calibrationSamples)
    filter = RotationOneEuroFilter()
    blend = TrackingBlend()
    distance = nil
    lastTime = nil
    receivedAnySample = false
    calibrationMisses = 0
    status = .calibrating

    pipeline = Task { @MainActor [weak self] in
      do {
        try await provider.start()
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.fail(
          L("カメラを開始できませんでした。", "Could not start the camera.") + " [\(error)]"
        )
        return
      }
      for await sample in provider.samples {
        guard let self, !Task.isCancelled else { return }
        self.process(sample)
      }
      // ストリームの終端は「カメラが止まった」の合図。自分で止めた（キャンセル済み）
      // のでなければ、追跡中の顔で UI が「使用中」を騙らないよう失敗へ落とす。
      guard let self, !Task.isCancelled, self.isEnabled else { return }
      self.fail(
        L("カメラが停止しました。もう一度オンにしてください。", "The camera stopped. Turn it on again.")
      )
    }

    // フレームが1枚も届かないままの沈黙（構成は成功したがカメラが黙っている）を
    // 較正表示のまま放置しない。
    watchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard let self, !Task.isCancelled else { return }
      if self.status == .calibrating, !self.receivedAnySample {
        self.fail(
          L("カメラから映像が届きません。", "No video is arriving from the camera.")
        )
      }
    }
  }

  private func process(_ sample: HeadPoseSample) {
    receivedAnySample = true
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
    pipeline?.cancel()
    pipeline = nil
    watchdog?.cancel()
    watchdog = nil
    provider?.stop()
    provider = nil
    lastTime = nil
    status = .failed(message)
    applyPose?(.forward, 1.0)
  }

  private func stopTracking() {
    pipeline?.cancel()
    pipeline = nil
    watchdog?.cancel()
    watchdog = nil
    provider?.stop()
    provider = nil
    lastTime = nil
    status = .off
    // 追従の置き土産を残さない: 音場は正面・較正距離へ戻す。
    applyPose?(.forward, 1.0)
  }

  private enum Keys {
    static let distance = "HeadTracking.distance"
  }
}
