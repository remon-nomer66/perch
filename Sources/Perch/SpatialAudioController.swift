import Foundation
import SpatialAudioKit

/// Drives the system-wide spatial audio from the notch's common sheet.
///
/// Device-independent: it captures and spatialises the Mac's own audio, so nothing here
/// depends on the connected headphones. Requires macOS 14.4+ (Core Audio process taps).
/// The on/off state is not persisted — a launch never starts capturing on its own; the
/// user turns it on when they want it. The sub-options are remembered.
@MainActor
final class SpatialAudioController: ObservableObject {
  @Published private(set) var isEnabled = false
  @Published private(set) var errorMessage: String?

  @Published var autoBalance: Bool {
    didSet {
      defaults.set(autoBalance, forKey: Keys.auto)
      reapplyIfRunning()
    }
  }
  @Published var wander: Bool {
    didSet {
      defaults.set(wander, forKey: Keys.wander)
      reapplyIfRunning()
    }
  }
  @Published var beat: Bool {
    didSet {
      defaults.set(beat, forKey: Keys.beat)
      reapplyIfRunning()
    }
  }

  /// The running spatialiser, type-erased so this controller need not itself be gated to
  /// macOS 14.4 (it is created only inside availability checks).
  private var engine: AnyObject?
  /// Fires shortly after start to catch a tap that never delivers audio — the shape a
  /// denied system-audio permission can take (it starts without error, then stays silent
  /// while the original audio is muted). Without this the user would sit in silence.
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
    if on { start() } else { stop() }
  }

  private func reapplyIfRunning() {
    guard isEnabled else { return }
    // The options are set at creation, so a change while running restarts the engine.
    start()
  }

  private func start() {
    guard #available(macOS 14.4, *) else { return }
    stop()
    do {
      let spatializer = try MultibandSpatializer(
        muteOriginal: true,
        autoBalance: autoBalance,
        wanderDegrees: wander ? 6 : 0,
        beatDegrees: beat ? 5 : 0
      )
      try spatializer.start()
      engine = spatializer
      isEnabled = true
      errorMessage = nil
      scheduleCaptureCheck()
    } catch {
      engine = nil
      isEnabled = false
      NSLog("Perch spatial: start failed: %@", String(describing: error))
      errorMessage = L(
        "空間オーディオを開始できませんでした。システムオーディオ録音の許可を確認してください。",
        "Could not start Spatial Audio. Check the system audio recording permission."
      ) + " [\(error)]"
    }
  }

  private func stop() {
    verifyTask?.cancel()
    verifyTask = nil
    if #available(macOS 14.4, *) {
      (engine as? MultibandSpatializer)?.stop()
    }
    engine = nil
    isEnabled = false
  }

  /// A tap can start without error yet deliver nothing when the system-audio permission
  /// is denied — and the original audio is muted meanwhile. If no capture has arrived
  /// shortly after start, treat it as a denial: put the sound back and say so.
  private func scheduleCaptureCheck() {
    verifyTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1500))
      guard let self, !Task.isCancelled, self.isEnabled else { return }
      guard #available(macOS 14.4, *), let engine = self.engine as? MultibandSpatializer else { return }
      if !engine.hasReceivedAudio {
        NSLog("Perch spatial: no audio captured within 1.5s; reverting (permission likely denied)")
        self.stop()
        self.errorMessage = L(
          "音声を取得できませんでした。システムオーディオ録音の許可を確認してください。",
          "No audio was captured. Check the system audio recording permission."
        )
      }
    }
  }

  private enum Keys {
    static let auto = "Spatial.autoBalance"
    static let wander = "Spatial.wander"
    static let beat = "Spatial.beat"
  }
}
