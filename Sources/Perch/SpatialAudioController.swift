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
      engine = try makeAndStartEngine()
      // Not on yet: the tap can start without error while the prompt is still up. Wait
      // for real audio before committing the switch to on.
      isStarting = true
      confirmCapture()
    } catch {
      NSLog("Perch spatial: start failed: %@", String(describing: error))
      teardown()
      errorMessage = L(
        "空間オーディオを開始できませんでした。システムオーディオ録音の許可を確認してください。",
        "Could not start Spatial Audio. Check the system audio recording permission."
      ) + " [\(error)]"
    }
  }

  /// Waits for capture to actually begin, giving a first-time permission prompt time to
  /// be answered. On the first buffer it commits to on; if none arrives it reverts and
  /// puts the original audio back, so a denial never strands the user in silence.
  private func confirmCapture() {
    verifyTask = Task { @MainActor [weak self] in
      for _ in 0..<15 {
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, !Task.isCancelled, self.isStarting else { return }
        if #available(macOS 14.4, *),
          (self.engine as? MultibandSpatializer)?.hasReceivedAudio == true {
          self.isStarting = false
          self.isEnabled = true
          self.errorMessage = nil
          return
        }
      }
      guard let self, self.isStarting else { return }
      NSLog("Perch spatial: no audio captured; reverting (permission likely denied)")
      self.teardown()
      self.errorMessage = L(
        "音声を取得できませんでした。システムオーディオ録音の許可を確認してください。",
        "No audio was captured. Check the system audio recording permission."
      )
    }
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
      errorMessage = nil
    } catch {
      teardown()
      errorMessage = L("空間オーディオを再設定できませんでした。", "Could not reconfigure Spatial Audio.")
    }
  }

  private func teardown() {
    verifyTask?.cancel()
    verifyTask = nil
    if #available(macOS 14.4, *) {
      (engine as? MultibandSpatializer)?.stop()
    }
    engine = nil
    isEnabled = false
    isStarting = false
  }

  private enum Keys {
    static let auto = "Spatial.autoBalance"
    static let wander = "Spatial.wander"
    static let beat = "Spatial.beat"
  }
}
