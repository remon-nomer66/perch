import Foundation
import SpatialAudioKit
import os

/// Drives the system-wide spatial audio from the notch's common sheet.
///
/// Device-independent: it captures and spatialises the Mac's own audio, so nothing here
/// depends on the connected headphones. Requires macOS 14.4+ (Core Audio process taps).
///
/// The switch reflects *confirmed* capture, not the mere attempt. Creating the tap
/// succeeds even without the system-audio recording grant — such a tap just delivers
/// silence — so turning on asks the tap itself whether recording is allowed, and turns
/// on at once when it is, even with nothing playing. When the tap cannot tell, real
/// audio has to arrive first. A refusal (or no audio) reverts and says why. While on,
/// the capture stays watched: a tap that falls silent while other apps play is rebuilt
/// once, then given up on. The policy lives in `CaptureSupervisor`. The on/off state is
/// not persisted; a launch never starts capturing on its own. The sub-options are
/// remembered.
@MainActor
final class SpatialAudioController: ObservableObject {
  @Published private(set) var isEnabled = false
  /// The gap between the user asking for it and capture being confirmed — while the
  /// system-audio prompt is up, or the first buffers are still on their way.
  @Published private(set) var isStarting = false
  @Published private(set) var errorMessage: String?
  /// Why the last attempt was given up, while its message is still showing.
  private(set) var revocation: CaptureSupervisor.Revocation?
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

  private static let log = Logger(subsystem: "dev.perch.mac", category: "spatial")

  private var engine: (any SpatialCaptureEngine)?
  /// The engine's audible-block count at the previous look; a new engine starts at zero.
  private var lastAudibleBlocks = 0
  private let makeEngine: SpatialEngineFactory
  private let othersPlaying: () -> Bool?
  private let timing: CaptureSupervisor.Timing
  private var supervisor: CaptureSupervisor?
  /// The last grant the tap reported, so the log records changes rather than every look.
  private var loggedPermission: SystemAudioPermission?
  private var superviseTask: Task<Void, Never>?
  private var tempoTask: Task<Void, Never>?
  private var configRebuildTask: Task<Void, Never>?
  private let defaults: UserDefaults

  /// Core Audio process taps — how the system audio is captured — arrived in macOS 14.4.
  var isAvailable: Bool {
    if #available(macOS 14.4, *) { return true }
    return false
  }

  /// - Parameters:
  ///   - makeEngine: builds and starts the capture engine. The default is the real
  ///     spatialiser over a process tap; tests pass a fake so no tap is ever created.
  ///   - othersPlaying: whether a process other than Perch is outputting audio (nil when
  ///     unreadable) — what tells a tap that lost capture from one that hears silence.
  ///   - timing: how often the capture is looked at, and how long each wait may last.
  init(
    defaults: UserDefaults = .standard,
    makeEngine: @escaping SpatialEngineFactory = SpatialEngines.makeSpatializer,
    othersPlaying: @escaping () -> Bool? = { AudibleProcesses.isAnotherProcessOutputting() },
    timing: CaptureSupervisor.Timing = CaptureSupervisor.Timing()
  ) {
    self.defaults = defaults
    self.makeEngine = makeEngine
    self.othersPlaying = othersPlaying
    self.timing = timing
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
      clearError()
      teardown()
    }
  }

  private var options: SpatialEngineOptions {
    SpatialEngineOptions(autoBalance: autoBalance, wander: wander, beat: beat)
  }

  /// Replaces the engine (if any) with a freshly built and started one.
  private func buildEngine() throws {
    engine?.stop()
    engine = nil
    lastAudibleBlocks = 0
    engine = try makeEngine(options) { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleEngineConfigurationChange()
      }
    }
  }

  private func start() {
    teardown()
    clearError()
    loggedPermission = nil
    do {
      // The first start raises the system-audio prompt. Whether capture is allowed is
      // asked of the tap afterwards, by the supervisor.
      try buildEngine()
    } catch {
      Self.log.error("start failed: \(String(describing: error), privacy: .public)")
      teardown()
      errorMessage = L(
        "空間オーディオを開始できませんでした。システムオーディオ録音の許可を確認してください。",
        "Could not start Spatial Audio. Check the system audio recording permission."
      ) + " [\(error)]"
      return
    }
    isStarting = true
    supervisor = CaptureSupervisor(timing: timing)
    superviseCapture()
  }

  /// Looks at the capture every tick and carries out what the supervisor decides — while
  /// turning on, then for as long as spatial audio stays on.
  private func superviseCapture() {
    superviseTask?.cancel()
    superviseTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let interval = self?.supervisor?.pollInterval else { return }
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self, self.superviseOnce() else { return }
      }
    }
  }

  /// One tick of supervision. Returns whether supervision goes on.
  private func superviseOnce() -> Bool {
    guard var supervisor, let engine else { return false }
    let audible = engine.audibleBlockCount
    let hasSignal = audible > lastAudibleBlocks
    lastAudibleBlocks = audible
    let decision = supervisor.observe(
      hasSignal: hasSignal,
      after: supervisor.pollInterval,
      othersPlaying: othersPlaying,
      permission: { probePermission(of: engine) }
    )
    self.supervisor = supervisor
    return carryOut(decision)
  }

  /// Asks the tap for the grant, logging the answer whenever it changes.
  private func probePermission(of engine: any SpatialCaptureEngine) -> SystemAudioPermission {
    let permission = engine.probeCapturePermission()
    if permission != loggedPermission {
      Self.log.notice(
        "system audio recording, as the tap reports it: \(String(describing: permission), privacy: .public)"
      )
      loggedPermission = permission
    }
    return permission
  }

  /// Returns whether supervision goes on.
  private func carryOut(_ decision: CaptureSupervisor.Decision) -> Bool {
    switch decision {
    case .hold:
      return true
    case .commit:
      Self.log.notice("capture confirmed; spatial audio on")
      isStarting = false
      isEnabled = true
      clearError()
      startTempoPolling()
      // From here on the same loop watches the running capture.
      return true
    case .rebuild:
      Self.log.notice(
        "\(self.isEnabled ? "tap silent while other audio plays" : "grant arrived while confirming", privacy: .public); rebuilding the tap"
      )
      do {
        try buildEngine()
        restoreListenerPose()
        return true
      } catch {
        Self.log.error("rebuild failed: \(String(describing: error), privacy: .public)")
        teardown()
        errorMessage = L(
          "空間オーディオを開始できませんでした。", "Could not start Spatial Audio."
        ) + " [\(error)]"
        return false
      }
    case .revoke(let reason):
      Self.log.notice("spatial audio given up: \(String(describing: reason), privacy: .public)")
      teardown()
      revocation = reason
      errorMessage = reason.message
      return false
    }
  }

  private func clearError() {
    errorMessage = nil
    revocation = nil
  }

  /// The last listener pose from head tracking, kept so an engine rebuild (options
  /// changed mid-listen) does not snap the sound field to front for the frames until
  /// the camera speaks again.
  private var listenerOrientation: SpatialAudioKit.ListenerOrientation?
  private var listenerDistanceRatio = 1.0

  /// The listener pose from head tracking. Only a running engine cares.
  func updateListenerPose(_ orientation: SpatialAudioKit.ListenerOrientation, distanceRatio: Double) {
    guard isEnabled else { return }
    listenerOrientation = orientation
    listenerDistanceRatio = distanceRatio
    engine?.updateListener(orientation)
    engine?.setListenerDistance(ratio: distanceRatio)
  }

  /// The output configuration changed under a live engine — headphones swapped for
  /// other headphones, a sample-rate change, a wake from sleep. AVAudioEngine stops
  /// itself and stays stopped, but the tap keeps muting the system: without a rebuild
  /// the whole Mac goes silent while the toggle still shows on. The route gate cannot
  /// catch this — headphones-to-headphones never flips `isHeadphones`. Rebuild here;
  /// if the new route is not headphones after all, the gate turns the feature off
  /// right after, which is the intended cascade.
  private func handleEngineConfigurationChange() {
    guard isEnabled || isStarting else { return }
    configRebuildTask?.cancel()
    configRebuildTask = Task { @MainActor [weak self] in
      // A device switch fires a burst of these; rebuild once, after it settles.
      try? await Task.sleep(for: .milliseconds(350))
      guard let self, !Task.isCancelled else { return }
      if self.isEnabled {
        self.reconfigureIfRunning()
      } else if self.isStarting {
        self.start()
      }
    }
  }

  /// A running engine with new options: rebuild in place, staying on. Capture is already
  /// confirmed, so no prompt and no waiting are involved.
  private func reconfigureIfRunning() {
    guard isEnabled else { return }
    do {
      try buildEngine()
      restoreListenerPose()
      clearError()
    } catch {
      Self.log.error("reconfigure failed: \(String(describing: error), privacy: .public)")
      teardown()
      errorMessage = L("空間オーディオを再設定できませんでした。", "Could not reconfigure Spatial Audio.")
    }
  }

  /// Hands a rebuilt engine the pose the previous one had.
  private func restoreListenerPose() {
    guard let listenerOrientation else { return }
    engine?.updateListener(listenerOrientation)
    engine?.setListenerDistance(ratio: listenerDistanceRatio)
  }

  /// Follows the engine's tempo estimate while capture runs. The engine object may be
  /// rebuilt underneath (option changes) — each tick reads whatever engine is current,
  /// so one task survives reconfigurations.
  private func startTempoPolling() {
    tempoTask?.cancel()
    tempoTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.isEnabled else { return }
        let bpm = self.engine?.estimatedBPM.map { $0.rounded() }
        if self.estimatedBPM != bpm { self.estimatedBPM = bpm }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func teardown() {
    superviseTask?.cancel()
    superviseTask = nil
    supervisor = nil
    tempoTask?.cancel()
    tempoTask = nil
    configRebuildTask?.cancel()
    configRebuildTask = nil
    estimatedBPM = nil
    engine?.stop()
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

extension CaptureSupervisor.Revocation {
  /// What the switch says when it reverts. Where the grant lives in System Settings is
  /// named as macOS 15+ labels it; the wording is the OS's to change, so it is hedged.
  var message: String {
    switch self {
    case .permissionDenied:
      L(
        "システムオーディオ録音が許可されていません。システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 の「システムオーディオ録音のみ」で Perch をオンにしてください（表記は macOS により異なることがあります）。",
        "System audio recording isn’t allowed. Turn on Perch under “System Audio Recording Only” in System Settings → Privacy & Security → Screen & System Audio Recording (names may vary by macOS version)."
      )
    case .noAudioDetected:
      L(
        "音声を検出できませんでした。何か再生してからお試しください。",
        "No audio detected. Play something, then try again."
      )
    case .captureLost:
      L(
        "再生中の音声を取り込めなくなったため、空間オーディオをオフにしました。続く場合は、システムオーディオ録音の許可を確認してください。",
        "Spatial Audio turned off because the playing audio could no longer be captured. If this keeps happening, check the system audio recording permission."
      )
    }
  }
}
