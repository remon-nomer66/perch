import CoreGraphics
import Foundation
import SpatialAudioKit

/// Drives the system-wide spatial audio from the notch's common sheet.
///
/// Device-independent: it captures and spatialises the Mac's own audio, so nothing here
/// depends on the connected headphones. Requires macOS 14.4+ (Core Audio process taps).
///
/// The switch reflects *confirmed* capture, not the mere attempt. Creating the tap
/// succeeds immediately even while the system-audio permission prompt is still up, and
/// audio only flows once it is granted — so turning on waits for real audio to arrive
/// before it commits. A denial (no audio) reverts and says why. The on/off state is not
/// persisted; a launch never starts capturing on its own. The sub-options are remembered.
@MainActor
final class SpatialAudioController: ObservableObject {
  @Published private(set) var isEnabled = false
  /// The gap between the user asking for it and capture being confirmed — while the
  /// system-audio prompt is up, or the first buffers are still on their way.
  @Published private(set) var isStarting = false
  @Published private(set) var errorMessage: String?
  /// The tempo the engine hears in whatever is playing, rounded to whole BPM.
  /// nil while off, or while no steady beat can be found.
  @Published private(set) var estimatedBPM: Double?

  @Published var autoBalance: Bool {
    didSet {
      defaults.set(autoBalance, forKey: Keys.auto)
      reconfigureIfRunning()
    }
  }
  @Published var wander: Bool {
    didSet {
      defaults.set(wander, forKey: Keys.wander)
      reconfigureIfRunning()
    }
  }
  @Published var beat: Bool {
    didSet {
      defaults.set(beat, forKey: Keys.beat)
      reconfigureIfRunning()
    }
  }

  /// The running spatialiser, type-erased so this controller need not itself be gated to
  /// macOS 14.4 (it is created only inside availability checks).
  private var engine: AnyObject?
  private var verifyTask: Task<Void, Never>?
  private var tempoTask: Task<Void, Never>?
  private let defaults: UserDefaults

  /// Core Audio process taps — how the system audio is captured — arrived in macOS 14.4.
  var isAvailable: Bool {
    if #available(macOS 14.4, *) { return true }
    return false
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    autoBalance = defaults.object(forKey: Keys.auto) as? Bool ?? true
    wander = defaults.object(forKey: Keys.wander) as? Bool ?? true
    beat = defaults.object(forKey: Keys.beat) as? Bool ?? false
  }

  func setEnabled(_ on: Bool) {
    guard isAvailable else { return }
    if on {
      guard !isEnabled, !isStarting else { return }
      start()
    } else {
      errorMessage = nil
      teardown()
    }
  }

  @available(macOS 14.4, *)
  private func makeAndStartEngine() throws -> MultibandSpatializer {
    let spatializer = try MultibandSpatializer(
      muteOriginal: true,
      autoBalance: autoBalance,
      wanderDegrees: wander ? 6 : 0,
      beatDegrees: beat ? 5 : 0
    )
    try spatializer.start()
    return spatializer
  }

  private func start() {
    guard #available(macOS 14.4, *) else { return }
    teardown()
    errorMessage = nil
    do {
      // Creating the tap raises the system-audio prompt the first time. Capture is
      // confirmed by real audio later; whether it works at all is a permission question,
      // answered separately below.
      engine = try makeAndStartEngine()
      isStarting = true
      confirmCapture(retryAfterGrant: true)
    } catch {
      NSLog("Perch spatial: start failed: %@", String(describing: error))
      teardown()
      errorMessage = L(
        "空間オーディオを開始できませんでした。システムオーディオ録音の許可を確認してください。",
        "Could not start Spatial Audio. Check the system audio recording permission."
      ) + " [\(error)]"
    }
  }

  /// Waits for *real* capture — a non-silent sample — before committing to on, then
  /// separates the two reasons it might not arrive:
  ///  1. Permission: the system-audio recording grant is a distinct, persistent state
  ///     (the same TCC as screen recording), read directly. If it is off, say only that.
  ///  2. Nothing playing: only once permission is confirmed does the audio matter.
  /// A tap created the instant the grant is given can stay silent, so a permitted-but-
  /// silent first attempt rebuilds the tap once before concluding nothing is playing.
  private func confirmCapture(retryAfterGrant: Bool) {
    verifyTask = Task { @MainActor [weak self] in
      for _ in 0..<15 {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, !Task.isCancelled, self.isStarting else { return }
        if #available(macOS 14.4, *),
          (self.engine as? MultibandSpatializer)?.hasAudioSignal == true {
          self.isStarting = false
          self.isEnabled = true
          self.errorMessage = nil
          self.startTempoPolling()
          return
        }
      }
      guard let self, self.isStarting else { return }

      // Phase 1 — permission. Rule it out first, and if it is the cause, say only that.
      guard CGPreflightScreenCaptureAccess() else {
        NSLog("Perch spatial: system-audio recording permission not granted")
        self.teardown()
        self.errorMessage = L(
          "「システムオーディオ録音」の許可がありません。設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で Perch をオンにしてください。",
          "System Audio Recording is not allowed. Turn Perch on in Settings → Privacy & Security → Screen & System Audio Recording."
        )
        return
      }

      // Permitted but silent. A tap made the moment the grant landed can stay silent —
      // rebuild it once before blaming the audio.
      if retryAfterGrant, #available(macOS 14.4, *) {
        NSLog("Perch spatial: permitted but silent; rebuilding tap once")
        (self.engine as? MultibandSpatializer)?.stop()
        self.engine = nil
        do {
          self.engine = try self.makeAndStartEngine()
          self.confirmCapture(retryAfterGrant: false)
        } catch {
          self.teardown()
          self.errorMessage = L(
            "空間オーディオを開始できませんでした。", "Could not start Spatial Audio."
          ) + " [\(error)]"
        }
        return
      }

      // Phase 2 — permitted, but no audio is playing.
      NSLog("Perch spatial: permitted but no audio captured; nothing playing")
      self.teardown()
      self.errorMessage = L(
        "音声が検出できませんでした。何か再生してからお試しください。",
        "No audio detected. Play something, then try again."
      )
    }
  }

  /// The last listener pose from head tracking, kept so an engine rebuild (options
  /// changed mid-listen) does not snap the sound field to front for the frames until
  /// the camera speaks again.
  private var listenerOrientation: SpatialAudioKit.ListenerOrientation?
  private var listenerDistanceRatio = 1.0

  /// The listener pose from head tracking. Only a running engine cares.
  func updateListenerPose(_ orientation: SpatialAudioKit.ListenerOrientation, distanceRatio: Double) {
    guard isEnabled, #available(macOS 14.4, *) else { return }
    listenerOrientation = orientation
    listenerDistanceRatio = distanceRatio
    let spatializer = engine as? MultibandSpatializer
    spatializer?.updateListener(orientation)
    spatializer?.setListenerDistance(ratio: distanceRatio)
  }

  /// A running engine with new options: rebuild in place, staying on. Capture is already
  /// confirmed, so no prompt and no waiting are involved.
  private func reconfigureIfRunning() {
    guard isEnabled, #available(macOS 14.4, *) else { return }
    verifyTask?.cancel()
    verifyTask = nil
    (engine as? MultibandSpatializer)?.stop()
    engine = nil
    do {
      engine = try makeAndStartEngine()
      if let listenerOrientation {
        let spatializer = engine as? MultibandSpatializer
        spatializer?.updateListener(listenerOrientation)
        spatializer?.setListenerDistance(ratio: listenerDistanceRatio)
      }
      errorMessage = nil
    } catch {
      teardown()
      errorMessage = L("空間オーディオを再設定できませんでした。", "Could not reconfigure Spatial Audio.")
    }
  }

  /// Follows the engine's tempo estimate while capture runs. The engine object may be
  /// rebuilt underneath (option changes) — each tick reads whatever engine is current,
  /// so one task survives reconfigurations.
  private func startTempoPolling() {
    tempoTask?.cancel()
    tempoTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.isEnabled else { return }
        if #available(macOS 14.4, *) {
          let bpm = (self.engine as? MultibandSpatializer)?
            .movementState.estimatedBPM.map { $0.rounded() }
          if self.estimatedBPM != bpm { self.estimatedBPM = bpm }
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func teardown() {
    verifyTask?.cancel()
    verifyTask = nil
    tempoTask?.cancel()
    tempoTask = nil
    estimatedBPM = nil
    if #available(macOS 14.4, *) {
      (engine as? MultibandSpatializer)?.stop()
    }
    engine = nil
    isEnabled = false
    isStarting = false
    listenerOrientation = nil
    listenerDistanceRatio = 1.0
  }

  private enum Keys {
    static let auto = "Spatial.autoBalance"
    static let wander = "Spatial.wander"
    static let beat = "Spatial.beat"
  }
}
