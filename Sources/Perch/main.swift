import AppKit
import Combine
import NotchKit
import PlayerBridge
import TandemCore
import SwiftUI
import TandemSession

// The notch panel driven by the live session: battery, codec, equaliser, noise
// control, listening mode, speak-to-chat, and call-time sidetone are all read from
// the headset.

/// Guards one panel field against the periodic refresh while writes are in flight.
///
/// Consecutive writes to the same field overlap: were the guard a plain flag, the
/// first write's completion would lift it while the second is still waiting, and the
/// refresh would snap the control back to the device's lagging value. Each `begin`
/// issues a fresh token; only the latest token's holder may lift the guard.
private struct AdjustmentGuard {
  private(set) var isHolding = false
  private var generation = 0

  mutating func begin() -> Int {
    generation += 1
    isHolding = true
    return generation
  }

  /// Lifts the guard, unless a later `begin` has superseded this token.
  mutating func end(_ token: Int) {
    if generation == token { isHolding = false }
  }

  /// Lifts the guard now and invalidates every outstanding token.
  mutating func cancel() {
    generation += 1
    isHolding = false
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var panel = PanelModel()
  @Published var page = 0

  var pager = PanelPager(pageCount: PanelPages.count)

  /// Sends a change and refreshes from what the device actually reports back.
  ///
  /// The panel is not updated optimistically: on an unverified model the headset may
  /// do something other than what was asked, and showing the requested value would
  /// hide exactly the mismatch worth seeing.
  private var levelDrag: Task<Void, Never>?
  /// While holding, the periodic refresh leaves the noise-control reading alone, so
  /// the device's not-yet-updated value cannot overwrite the level being dragged.
  private var levelAdjustment = AdjustmentGuard()
  /// While holding, the periodic refresh leaves the listening reading alone so a
  /// device that takes a moment to apply a mode change cannot snap the picker back.
  private var listeningAdjustment = AdjustmentGuard()

  func applyListening(_ target: TandemListeningSelection, using service: SessionService) {
    guard let current = panel.listeningMode else { return }
    let savedRoom: TandemListeningRoom
    if case .backgroundMusic(let room) = target { savedRoom = room } else { savedRoom = current.savedRoom }
    let token = listeningAdjustment.begin()
    panel.listeningMode = TandemListeningReading(
      features: current.features,
      selection: target,
      savedRoom: savedRoom
    )
    Task {
      let session = await service.session
      try? await session.apply(listeningSelection: target)
      await refresh(from: service)
      listeningAdjustment.end(token)
    }
  }

  func applyNoiseControl(_ target: TandemNoiseControlState, using service: SessionService) {
    levelDrag?.cancel()
    levelAdjustment.cancel()
    Task {
      let session = await service.session
      try? await session.apply(noiseControl: target)
      await refresh(from: service)
    }
  }

  /// Called repeatedly while the level slider is dragged, and once more on release.
  ///
  /// The target is built from the current reading each time, so the release sends the
  /// value the finger actually settled on rather than a stale captured one.
  /// Intermediate values are debounced and sent as non-final; only the release is read
  /// back and reflected in the panel.
  func dragNoiseLevel(level: Int, isFinal: Bool, using service: SessionService) {
    guard let reading = panel.noiseControl else { return }
    let clamped = reading.quantizedLevel(level, mode: reading.state.ambientMode)
    let target = TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: false,
      ambientMode: reading.state.ambientMode,
      ambientLevel: clamped,
      noiseAdaptation: reading.state.noiseAdaptation
    )

    // Own the level for the whole gesture, including the final read-back, so the
    // periodic refresh cannot overwrite the slider with the device's lagging value
    // before the confirmation lands.
    let token = levelAdjustment.begin()
    panel.noiseControl = NoiseControlReading(
      inquiry: reading.inquiry,
      modes: reading.modes,
      state: target,
      valueFieldCount: reading.valueFieldCount,
      legacyWindKind: reading.legacyWindKind
    )

    levelDrag?.cancel()
    levelDrag = Task {
      if !isFinal {
        try? await Task.sleep(for: .milliseconds(90))
        if Task.isCancelled { return }
      }
      let session = await service.session
      try? await session.apply(noiseControl: target, isFinal: isFinal)
      if isFinal {
        await refresh(from: service)
        levelAdjustment.end(token)
      }
    }
  }

  /// While holding, the periodic refresh leaves the equaliser reading alone so a band
  /// drag or preset change is not snapped back by the device's lagging value.
  private var equalizerAdjustment = AdjustmentGuard()
  private var bandDrag: Task<Void, Never>?

  /// Selects a preset. The bands are left empty so the device loads the preset's own
  /// curve rather than being handed the current custom values.
  func applyEqualizerPreset(
    _ identifier: UInt8, bandSteps: [UInt8] = [], using service: SessionService
  ) {
    guard let reading = panel.equalizer else { return }
    bandDrag?.cancel()
    let token = equalizerAdjustment.begin()
    panel.equalizer = Self.equalizer(
      reading,
      selectedPreset: identifier,
      bandSteps: bandSteps.isEmpty ? reading.bandSteps : bandSteps.map(Int.init)
    )
    Task {
      let session = await service.session
      try? await session.apply(equalizerPreset: identifier, bandSteps: bandSteps)
      await refresh(from: service)
      equalizerAdjustment.end(token)
    }
  }

  /// Called while a band is dragged and once on release. Editing a band lands on the
  /// device's custom preset; a device without one cannot be edited and is guarded out.
  func dragEqualizerBand(index: Int, step: Int, isFinal: Bool, using service: SessionService) {
    guard let reading = panel.equalizer, let presetIdentifier = reading.editablePresetIdentifier
    else { return }
    let bands = reading.settingBand(index, toStep: step)
    // The settled curve is remembered app-side as well as by the device, so the
    // user's own shape survives the device being adjusted from elsewhere.
    if isFinal { onBandsCommitted?(presetIdentifier, bands.map(Int.init)) }
    let token = equalizerAdjustment.begin()
    panel.equalizer = Self.equalizer(
      reading,
      selectedPreset: presetIdentifier,
      bandSteps: bands.map(Int.init)
    )
    bandDrag?.cancel()
    bandDrag = Task {
      if !isFinal {
        try? await Task.sleep(for: .milliseconds(90))
        if Task.isCancelled { return }
      }
      let session = await service.session
      try? await session.apply(
        equalizerPreset: presetIdentifier,
        bandSteps: bands,
        isFinal: isFinal
      )
      if isFinal {
        await refresh(from: service)
        equalizerAdjustment.end(token)
      }
    }
  }

  /// A copy of an equaliser reading with the selection and bands replaced, for the
  /// optimistic update shown while a write is in flight.
  private static func equalizer(
    _ reading: EqualizerReading,
    selectedPreset: UInt8,
    bandSteps: [Int]
  ) -> EqualizerReading {
    EqualizerReading(
      presets: reading.presets,
      selectedPreset: selectedPreset,
      bandFrequencies: reading.bandFrequencies,
      bandSteps: bandSteps,
      stepRange: reading.stepRange,
      flatStep: reading.flatStep
    )
  }

  /// Presentation debounce for the unreachable status; see `UnreachableDebounce`.
  private var unreachableDebounce = UnreachableDebounce()
  /// False until the launch-time permission serialisation lifts it: while false, the
  /// periodic refresh does not query the players over Apple Events, so the automation
  /// prompts cannot land on top of the Bluetooth one.
  var playerQueriesAllowed = false

  /// The quiet mode's connection announcement, tracked here rather than in the view:
  /// the panel view can be absent or rebuilt across the transition (notch toggled,
  /// language switched), and an announcement owned by view state dies with it.
  private var hadContent = false
  private var arrivalAnnounceUntil: ContinuousClock.Instant?

  /// Pulls what the session knows into the shape the panel draws.
  func refresh(from service: SessionService) async {
    // Asked first: the Apple Events answer can take up to its deadline, and the
    // guarded panel fields below must be read and published without that wait
    // sitting between them.
    let nowPlaying = playerQueriesAllowed ? await nowPlayingService.read() : nil
    let session = await service.session
    let phase = await session.phase
    let fingerprint = await session.deviceFingerprint
    let reason = await session.unsupportedReason
    let acceptsWrites = await session.acceptsWrites

    var next = PanelModel()
    next.summary.status = unreachableDebounce.present(
      DeviceSummary.status(for: phase, reason: reason)
    )
    next.summary.modelName = fingerprint?.modelName
    next.summary.firmwareVersion = fingerprint?.firmwareVersion
    next.summary.acceptsWrites = acceptsWrites

    let readings = await session.readings
    next.summary.codec = readings.codec?.description
    next.equalizer = equalizerAdjustment.isHolding ? panel.equalizer : readings.equalizer
    next.listeningMode = listeningAdjustment.isHolding ? panel.listeningMode : readings.listeningMode
    next.speakToChat = speakToChatAdjustment.isHolding ? panel.speakToChat : readings.speakToChat
    next.sidetone = sidetoneAdjustment.isHolding ? panel.sidetone : readings.sidetone
    // A drag in progress owns the level; the device's lagging value must not clobber
    // it mid-gesture.
    next.noiseControl = levelAdjustment.isHolding ? panel.noiseControl : readings.noiseControl
    next.battery = Self.batteryLayout(for: fingerprint, readings: readings)
    next.nowPlaying = nowPlaying.map {
      PanelModel.NowPlaying(
        title: $0.title,
        artist: $0.artist,
        isPlaying: $0.isPlaying,
        artworkURL: $0.artworkURL
      )
    }
    // A device that went away takes the editor preview with it: there is nothing left
    // to put back, and stale values must not land on the next device.
    if !next.summary.isControllable {
      previewHold = PreviewHold()
      // The rule's undo dies with the device for the same reason: what reconnects
      // may be a different device, and the old restore values belong to the old one.
      ruleHold = nil
    }

    // The same condition NotchPanelView.hasContent widens the bar by: its rising
    // edge opens the five-second announcement window the quiet mode shows.
    let hasContent = next.summary.isControllable
      && (next.summary.modelName != nil || next.battery != .unknown)
    if hasContent, !hadContent {
      arrivalAnnounceUntil = ContinuousClock.now.advanced(by: .seconds(5))
    }
    if !hasContent { arrivalAnnounceUntil = nil }
    hadContent = hasContent
    next.announcesArrival = arrivalAnnounceUntil.map { ContinuousClock.now < $0 } ?? false

    if panel != next { panel = next }
  }

  private let nowPlayingService = NowPlayingService(onAutomationDenied: {
    Task { @MainActor in AutomationPermission.shared.notePlayerDenied() }
  })

  func nowPlayingPlayPause() { nowPlayingService.playPause() }
  func nowPlayingNext() { nowPlayingService.next() }
  func nowPlayingPrevious() { nowPlayingService.previous() }

  private var speakToChatAdjustment = AdjustmentGuard()

  func applySpeakToChat(enabled: Bool, using service: SessionService) {
    guard let current = panel.speakToChat else { return }
    let token = speakToChatAdjustment.begin()
    panel.speakToChat = Self.speakToChat(current, isEnabled: enabled)
    Task {
      let session = await service.session
      try? await session.apply(speakToChatEnabled: enabled)
      await refresh(from: service)
      speakToChatAdjustment.end(token)
    }
  }

  func applySpeakToChatDetail(
    sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout,
    using service: SessionService
  ) {
    guard let current = panel.speakToChat else { return }
    let token = speakToChatAdjustment.begin()
    panel.speakToChat = Self.speakToChat(current, sensitivity: sensitivity, timeout: timeout)
    Task {
      let session = await service.session
      try? await session.apply(speakToChatSensitivity: sensitivity, timeout: timeout)
      await refresh(from: service)
      speakToChatAdjustment.end(token)
    }
  }

  private static func speakToChat(
    _ reading: SpeakToChatReading,
    isEnabled: Bool? = nil,
    sensitivity: TandemSpeakToChatSensitivity? = nil,
    timeout: TandemSpeakToChatTimeout? = nil
  ) -> SpeakToChatReading {
    SpeakToChatReading(
      inquiry: reading.inquiry,
      capability: reading.capability,
      isEnabled: isEnabled ?? reading.isEnabled,
      secondarySettingEnabled: reading.secondarySettingEnabled,
      sensitivity: sensitivity ?? reading.sensitivity,
      timeout: timeout ?? reading.timeout
    )
  }

  /// While holding, the periodic refresh leaves the sidetone reading alone so the
  /// device's not-yet-updated value cannot snap the switch back mid-write.
  private var sidetoneAdjustment = AdjustmentGuard()

  func applySidetone(enabled: Bool, using service: SessionService) {
    guard let current = panel.sidetone else { return }
    let token = sidetoneAdjustment.begin()
    panel.sidetone = SidetoneReading(
      slot: current.slot,
      snapshot: TandemGeneralSettingSnapshot(
        capability: current.snapshot.capability,
        isControlEnabled: current.snapshot.isControlEnabled,
        value: .boolean(enabled)
      )
    )
    Task {
      let session = await service.session
      try? await session.apply(sidetoneEnabled: enabled)
      await refresh(from: service)
      sidetoneAdjustment.end(token)
    }
  }

  /// The device says how many enclosures it has by which battery functions it
  /// declares. Nothing is assumed from the model name.
  private static func batteryLayout(
    for fingerprint: TandemDeviceFingerprint?,
    readings: DeviceReadings
  ) -> BatteryLayout {
    guard let fingerprint else { return .unknown }
    switch fingerprint.housing {
    case .separateLeftRight:
      return .leftRight(
        left: readings.leftBattery,
        right: readings.rightBattery,
        charging: readings.caseBattery
      )
    case .single:
      return .single(readings.singleBattery)
    case .unknown:
      return .unknown
    }
  }

  // MARK: - Automation rules

  /// Wired by the app delegate to the settings store's remembered custom curves.
  var bandMemory: ((UInt8) -> [Int]?)?
  var onBandsCommitted: ((UInt8, [Int]) -> Void)?

  /// What the active rule changed, and what to put back. Restoration is per field and
  /// only while the value is still the rule's own: a manual change wins.
  private struct RuleHold {
    let ruleID: UUID
    var noise: (previous: TandemNoiseControlState, applied: TandemNoiseControlState)?
    var equalizer: (previous: UInt8, applied: UInt8)?
    var listening: (previous: TandemListeningSelection, applied: TandemListeningSelection)?
  }
  private var ruleHold: RuleHold?

  func playingSource() async -> String? { await nowPlayingService.playingBundleID() }

  /// Applies the matched rule, first undoing whichever rule held before it.
  ///
  /// A hold is kept even when the rule changed nothing, so a source that is already
  /// set up right does not have later manual adjustments captured as its own.
  func applyRule(_ rule: SoundRule?, using service: SessionService) {
    // The hold being replaced is kept around: its restore writes are still in
    // flight, so for a field both rules touch the panel still shows the old rule's
    // value — the true original lives only in the old hold.
    var replaced: RuleHold?
    if let hold = ruleHold, hold.ruleID != rule?.id {
      release(hold, using: service)
      replaced = hold
      ruleHold = nil
    }
    guard let rule, ruleHold == nil else { return }

    var hold = RuleHold(ruleID: rule.id)
    // Whether any field the rule asks for had a reading to judge against. Right
    // after a connect none has arrived yet; registering the hold then would count
    // the rule as applied while nothing was, and the guard above would never let
    // it try again.
    var sawRequestedReading = false

    if rule.noise != .keep, let reading = panel.noiseControl {
      sawRequestedReading = true
      if let target = Self.noiseTarget(rule.noise, reading) {
        let previous = replaced?.noise?.previous ?? reading.state
        if previous != target {
          hold.noise = (previous, target)
          applyNoiseControl(target, using: service)
        }
      }
    }

    if let preset = rule.equalizerPreset, let reading = panel.equalizer {
      sawRequestedReading = true
      if reading.presets.contains(where: { $0.identifier == preset }),
        !equalizerBlocked(by: rule),
        let previous = replaced?.equalizer?.previous ?? reading.selectedPreset,
        previous != preset
      {
        hold.equalizer = (previous, preset)
        selectPreset(preset, from: reading, using: service)
      }
    }

    if rule.listening != .keep, let reading = panel.listeningMode {
      sawRequestedReading = true
      if let target = Self.listeningTarget(rule.listening, reading) {
        let previous = replaced?.listening?.previous ?? reading.selection
        if previous != target {
          hold.listening = (previous, target)
          applyListening(target, using: service)
        }
      }
    }

    guard sawRequestedReading else { return }
    ruleHold = hold
  }

  private func release(_ hold: RuleHold, using service: SessionService) {
    if let (previous, applied) = hold.noise, panel.noiseControl?.state == applied {
      applyNoiseControl(previous, using: service)
    }
    if let (previous, applied) = hold.equalizer, panel.equalizer?.selectedPreset == applied {
      applyEqualizerPreset(previous, using: service)
    }
    if let (previous, applied) = hold.listening, panel.listeningMode?.selection == applied {
      applyListening(previous, using: service)
    }
  }

  /// The device switches its equaliser off while a listening mode runs, so a rule's
  /// preset only lands when the mode the rule leaves the device in is standard. The
  /// editor refuses the combination; this also guards rules stored before it did.
  private func equalizerBlocked(by rule: SoundRule) -> Bool {
    switch rule.listening {
    case .backgroundMusic, .cinema: true
    case .standard: false
    case .keep: panel.listeningMode?.disablesEqualizer ?? false
    }
  }

  /// The same targets the noise sheet's tiles send, built from the current state so
  /// levels and focus stay where the user left them. Nil when the device's dialect
  /// does not have the asked-for mode. Internal: this is the rule engine's pure
  /// decision core, exercised directly by the tests.
  static func noiseTarget(
    _ action: SoundRule.NoiseAction, _ reading: NoiseControlReading
  ) -> TandemNoiseControlState? {
    let current = reading.state
    switch action {
    case .keep:
      return nil
    case .noiseCancelling:
      guard reading.supportsNoiseCancelling else { return nil }
      return TandemNoiseControlState(
        isActive: true,
        isNoiseCancelling: true,
        ambientMode: current.ambientMode,
        ambientLevel: current.ambientLevel,
        noiseAdaptation: current.noiseAdaptation
      )
    case .ambient:
      guard reading.supportsAmbient else { return nil }
      return TandemNoiseControlState(
        isActive: true,
        isNoiseCancelling: false,
        ambientMode: current.ambientMode,
        ambientLevel: current.ambientLevel,
        noiseAdaptation: current.noiseAdaptation
      )
    case .off:
      return TandemNoiseControlState(
        isActive: false,
        isNoiseCancelling: false,
        ambientMode: current.ambientMode,
        ambientLevel: current.ambientLevel,
        noiseAdaptation: current.noiseAdaptation
      )
    }
  }

  /// Internal like `noiseTarget`, and for the same reason.
  static func listeningTarget(
    _ action: SoundRule.ListeningAction, _ reading: TandemListeningReading
  ) -> TandemListeningSelection? {
    switch action {
    case .keep: nil
    case .standard: .standard
    case .backgroundMusic: reading.hasBackgroundMusic ? .backgroundMusic(reading.savedRoom) : nil
    case .cinema: reading.hasCinema ? .cinema : nil
    }
  }

  /// Selects a preset the way a rule does: an editable preset carries the user's own
  /// remembered curve, so what is heard is the shape the rule will actually apply.
  private func selectPreset(
    _ preset: UInt8, from reading: EqualizerReading, using service: SessionService
  ) {
    if reading.editablePresetIdentifier == preset, let steps = bandMemory?(preset) {
      applyEqualizerPreset(preset, bandSteps: steps.map(UInt8.init), using: service)
    } else {
      applyEqualizerPreset(preset, using: service)
    }
  }

  // MARK: - Rule editor live preview

  /// What the rule editor's preview changed, and what to put back. Each choice made in
  /// the editor lands on the device at once, so the candidate can be judged by ear;
  /// registering the rule or leaving the editor puts the previewed fields back.
  ///
  /// Restoration follows `RuleHold`'s manner: per field, and only while the value is
  /// still the preview's own — a change made elsewhere in between wins.
  private struct PreviewHold {
    var noise: (previous: TandemNoiseControlState, applied: TandemNoiseControlState)?
    var equalizer: (previous: UInt8, applied: UInt8)?
    var listening: (previous: TandemListeningSelection, applied: TandemListeningSelection)?
  }
  private var previewHold = PreviewHold()

  /// True while the audition holds anything. The rule watch loop reads this and
  /// stands down: a rule applied mid-preview would overwrite the value being judged
  /// and record it as the state to put back.
  var isPreviewing: Bool {
    previewHold.noise != nil || previewHold.equalizer != nil || previewHold.listening != nil
  }

  func previewNoise(_ action: SoundRule.NoiseAction, using service: SessionService) {
    guard action != .keep else { return restorePreviewedNoise(using: service) }
    guard let reading = panel.noiseControl, let target = Self.noiseTarget(action, reading)
    else { return }
    if previewHold.noise == nil {
      guard reading.state != target else { return }
      previewHold.noise = (reading.state, target)
    } else {
      previewHold.noise?.applied = target
    }
    applyNoiseControl(target, using: service)
  }

  func previewEqualizerPreset(_ identifier: Int, using service: SessionService) {
    guard identifier >= 0 else { return restorePreviewedEqualizer(using: service) }
    let preset = UInt8(clamping: identifier)
    guard let reading = panel.equalizer, let current = reading.selectedPreset,
      reading.presets.contains(where: { $0.identifier == preset })
    else { return }
    if previewHold.equalizer == nil {
      guard current != preset else { return }
      previewHold.equalizer = (current, preset)
    } else {
      previewHold.equalizer?.applied = preset
    }
    selectPreset(preset, from: reading, using: service)
  }

  func previewListening(_ action: SoundRule.ListeningAction, using service: SessionService) {
    guard action != .keep else { return restorePreviewedListening(using: service) }
    guard let reading = panel.listeningMode, let target = Self.listeningTarget(action, reading)
    else { return }
    if previewHold.listening == nil {
      guard reading.selection != target else { return }
      previewHold.listening = (reading.selection, target)
    } else {
      previewHold.listening?.applied = target
    }
    applyListening(target, using: service)
  }

  /// Ends the preview, putting back everything it changed — called when the rule is
  /// registered and when the editor goes away.
  func endPreview(using service: SessionService) {
    restorePreviewedNoise(using: service)
    restorePreviewedEqualizer(using: service)
    restorePreviewedListening(using: service)
  }

  private func restorePreviewedNoise(using service: SessionService) {
    guard let (previous, applied) = previewHold.noise else { return }
    previewHold.noise = nil
    if panel.noiseControl?.state == applied { applyNoiseControl(previous, using: service) }
  }

  private func restorePreviewedEqualizer(using service: SessionService) {
    guard let (previous, applied) = previewHold.equalizer else { return }
    previewHold.equalizer = nil
    if panel.equalizer?.selectedPreset == applied {
      applyEqualizerPreset(previous, using: service)
    }
  }

  private func restorePreviewedListening(using service: SessionService) {
    guard let (previous, applied) = previewHold.listening else { return }
    previewHold.listening = nil
    if panel.listeningMode?.selection == applied { applyListening(previous, using: service) }
  }

  func scroll(_ event: NSEvent) {
    let phase: PanelPager.Phase =
      switch event.phase {
      case .began: .began
      case .changed: .changed
      case .ended, .cancelled: .ended
      default: .none
      }
    // The pages sit side by side under a horizontal indicator, so the panel is paged by
    // horizontal scrolling to match what the dots promise.
    let outcome = pager.handle(
      .init(
        delta: event.scrollingDeltaX,
        phase: phase,
        isMomentum: event.momentumPhase != []
      )
    )
    if case .moved(let index) = outcome {
      page = index
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let service = SessionService.live()
  private let model = AppModel()
  private let appearanceStore = NotchAppearanceStore()
  private let settingsStore = AppSettingsStore()
  private var settingsWindow: NSWindow?
  /// Watches the settings window's close, which SwiftUI's `onDisappear` does not see.
  private var settingsCloseObserver: (any NSObjectProtocol)?
  private var controller: NotchController?
  private var statusItem: NSStatusItem?
  private var scrollMonitor: Any?
  private var cancellables: Set<AnyCancellable> = []
  private var mediaGestures: MediaGestureForwarder?
  private let fullScreen = FullScreenMonitor()

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = self.model
    let appearanceStore = self.appearanceStore
    let settingsStore = self.settingsStore
    let service = self.service
    let controller = NotchController(
      appearance: { appearanceStore.appearance }
    ) { presentation in
      NotchPanelBridge(
        model: model,
        appearanceStore: appearanceStore,
        settingsStore: settingsStore,
        service: service,
        presentation: presentation,
        openSettings: { [weak self] in
          MainActor.assumeIsolated {
            // The gear hands the stage over: the panel shrinks back into the notch
            // as the settings window comes up.
            self?.controller?.dismiss()
            self?.openSettings()
          }
        }
      )
    }
    controller.onUsableNotchChanged = { [weak self] _ in
      // Without a notch there is nothing to point at, so the item is not optional
      // whichever way the notch went.
      MainActor.assumeIsolated { self?.installStatusItem() }
    }
    // The hover target follows the bar's drawn size: while the bar stays bare —
    // nothing to carry yet, or quiet mode with the panel closed — only the cutout
    // itself reacts to the pointer, not the invisible side reaches of the hidden bar.
    controller.isBarVisible = { [weak controller] in
      guard let controller else { return true }
      let summary = model.panel.summary
      // The same condition NotchPanelView.hasContent widens the bar by.
      let hasContent = summary.isControllable
        && (summary.modelName != nil || model.panel.battery != .unknown)
      guard hasContent else { return false }
      return settingsStore.notchDisplayMode == .always || controller.presentation != .closed
    }
    self.controller = controller

    // The notch obeys the setting from launch onward, and — when so asked — steps
    // aside while the notch screen is taken full screen, following the menu bar out
    // of the way. Every publisher fires immediately with its stored value, so this
    // also decides the state at launch.
    let fullScreenTaken = CurrentValueSubject<Bool, Never>(fullScreen.isFullScreen)
    fullScreen.onChange = { taken in fullScreenTaken.send(taken) }
    Publishers.CombineLatest(
      settingsStore.$isNotchEnabled,
      settingsStore.$hidesNotchInFullScreen
    )
    // The monitor only runs while its answer matters — the notch enabled *and* asked
    // to step aside. With the notch off entirely, polling the window list would be
    // work in service of nothing. stop() reports "not taken", so switching either
    // option off brings the notch straight back.
    .map { enabled, hide in enabled && hide }
    .removeDuplicates()
    .sink { [fullScreen] watch in
      if watch { fullScreen.start() } else { fullScreen.stop() }
    }
    .store(in: &cancellables)

    Publishers.CombineLatest3(
      settingsStore.$isNotchEnabled,
      settingsStore.$hidesNotchInFullScreen,
      fullScreenTaken
    )
    .map { enabled, hideInFullScreen, taken in enabled && !(hideInFullScreen && taken) }
    .removeDuplicates()
    .sink { [weak controller] show in
      guard let controller else { return }
      if show { controller.start() } else { controller.stop() }
    }
    .store(in: &cancellables)

    // The panel lives in a non-activating panel, so scroll events reach it only
    // through a monitor.
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      MainActor.assumeIsolated {
        if controller.presentation == .opened { model.scroll(event) }
      }
      return event
    }

    // Settings open from the menu bar item: the notch being adjusted may be mis-sized
    // enough to be hard to point at, and the icon doubles as the visible sign that the
    // app is running at all.
    installStatusItem()

    // An accessory app has no menu bar of its own, but without a main menu the edit
    // key equivalents — paste above all — have nowhere to land, and the settings
    // window's text fields go deaf to ⌘V.
    installMainMenu()

    // Menus and the window title keep the strings they were built with, so a language
    // change rebuilds them. SwiftUI re-renders on its own: the views observe the store
    // and re-read their `L(_:_:)` pairs. The publisher fires before the store property
    // updates, so the global is set here from the payload rather than the store.
    settingsStore.$language
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] language in
        guard let self else { return }
        L10n.language = language
        self.statusItem?.menu = self.buildStatusMenu(current: language)
        self.installMainMenu()
        self.settingsWindow?.title = L("設定", "Settings")
      }
      .store(in: &cancellables)

    // The bar icon follows the connection. The panel refreshes twice a second, so
    // only actual state flips reach the icon.
    model.$panel
      .map(\.summary.isControllable)
      .removeDuplicates()
      .sink { [weak self] connected in self?.updateStatusIcon(connected: connected) }
      .store(in: &cancellables)

    Task {
      await service.start()
      while !Task.isCancelled {
        await model.refresh(from: service)
        try? await Task.sleep(for: .milliseconds(500))
      }
    }

    // A first launch has up to three permission prompts to show — Bluetooth, and
    // automation for each player — and firing them together buries one dialog under
    // another. Bluetooth (the session) goes first alone; the Apple-Events side — the
    // now-playing readout and the rule engine's queries — waits until the session
    // has a controllable device or ten seconds pass, whichever comes first.
    Task { [model] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while ContinuousClock.now < deadline, !model.panel.summary.isControllable {
        try? await Task.sleep(for: .milliseconds(250))
      }
      model.playerQueriesAllowed = true
    }

    // Holding the control channel open stops the headset from sending its touch-panel
    // play/skip gestures as media keys; it reports them over the channel instead. Re-
    // issue those through the same player transport the notch buttons use so the ear
    // controls keep working. Volume is left alone — the headset still applies that.
    let mediaGestures = MediaGestureForwarder(
      service: service,
      transport: .init(
        playPause: { [model] in model.nowPlayingPlayPause() },
        next: { [model] in model.nowPlayingNext() },
        previous: { [model] in model.nowPlayingPrevious() }
      )
    )
    mediaGestures.start()
    self.mediaGestures = mediaGestures

    // The automation watch on its own slow cadence: at most one Apple Events round
    // trip every two seconds, and only while rules exist and are switched on.
    model.bandMemory = { preset in settingsStore.customBandSteps["\(preset)"] }
    model.onBandsCommitted = { preset, steps in settingsStore.customBandSteps["\(preset)"] = steps }
    Task {
      while !Task.isCancelled {
        if !model.playerQueriesAllowed {
          // The launch-time permission serialisation above has not lifted the gate
          // yet; a rule pass now would fire the very automation prompts it delays.
        } else if model.isPreviewing {
          // The rule editor's audition owns the device. Neither applying a rule nor
          // releasing an existing hold may run under it: the engine freezes as it
          // stands and resumes once the preview ends.
        } else if settingsStore.isRulesEnabled, !settingsStore.rules.isEmpty {
          // The playing player is what the ears are on; while none plays, a rule's
          // app matches by being frontmost and site rules speak through the visible
          // tabs. The rule list's order settles any tie.
          let playing = await model.playingSource()
          let frontmost =
            playing == nil ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
          // Browsers are only asked while a site rule could use the answer: the
          // query is what surfaces the automation-permission prompts and reads the
          // open tabs, and a rule set of app triggers justifies neither.
          let hasSiteRule = settingsStore.rules.contains { rule in
            if case .site = rule.trigger { return true }
            return false
          }
          let hosts =
            playing == nil && hasSiteRule ? await SiteWatcher.visibleTabHosts() : []
          let matched = settingsStore.rules.first { rule in
            switch rule.trigger {
            case .app(let bundleID):
              playing == bundleID || (playing == nil && frontmost == bundleID)
            case .site(let domain):
              playing == nil && SiteWatcher.matches(hosts: hosts, sites: [domain])
            }
          }
          model.applyRule(matched, using: service)
        } else {
          model.applyRule(nil, using: service)
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  // Reached when the already-running app is opened again from Launchpad or the
  // Applications folder. With no Dock icon that double-click is the one way a user
  // reaches for the GUI, so it brings up the settings window.
  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    openSettings()
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    // A live preview must not outlive the app: whatever the rule editor changed goes
    // back before the session below is stopped. The restore writes are queued as
    // main-actor tasks, so the run loop gets a brief beat to start them here — once
    // they hop onto the session's actor they run ahead of the stop that follows.
    // Blocking on the semaphore below first would leave them queued forever.
    model.endPreview(using: service)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    mediaGestures?.stop()
    controller?.stop()
    // The process dies when this returns, and a fire-and-forget task has no
    // guarantee of running before it does. Wait for the session to actually stop —
    // the RFCOMM control channel must close for the headset to serve the next
    // connection — but with a bound, so a wedged session cannot hold quitting
    // hostage. Detached, because this wait blocks the main thread the plain Task
    // would have needed.
    let service = self.service
    let stopped = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
      await service.stop()
      stopped.signal()
    }
    _ = stopped.wait(timeout: .now() + .seconds(2))
  }

  private func updateStatusItem(notchAvailable: Bool) {
    // Without a notch there is nothing to point at, so the item is not optional.
    installStatusItem()
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()

    // ⌘W must land somewhere: without a close item the settings window can only be
    // closed by pointing at its button. performClose goes through the responder
    // chain, so it reaches whichever window is key.
    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: L("ファイル", "File"))
    fileMenu.addItem(
      withTitle: L("閉じる", "Close Window"),
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: L("編集", "Edit"))
    editMenu.addItem(withTitle: L("取り消す", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: L("やり直す", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: L("カット", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: L("コピー", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: L("ペースト", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: L("すべてを選択", "Select All"),
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApp.mainMenu = mainMenu
  }

  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = buildStatusMenu(current: settingsStore.language)
    statusItem = item
    updateStatusIcon(connected: model.panel.summary.isControllable)
  }

  /// The bar icon doubles as the connection light: the coloured mark while a device
  /// is controllable, its monochrome cut as a template otherwise — the system draws
  /// that one black or white to match the menu bar and inverts it while clicked.
  private func updateStatusIcon(connected: Bool) {
    statusItem?.button?.image = connected ? Self.colorIcon : Self.templateIcon
  }

  private static let colorIcon = menuIcon(named: "MenuIconColor", isTemplate: false)
  private static let templateIcon = menuIcon(named: "MenuIconTemplate", isTemplate: true)

  private static func menuIcon(named name: String, isTemplate: Bool) -> NSImage? {
    // The bundle should always carry the artwork; a bare symbol beats an empty slot
    // in the bar if it somehow does not. The symbol is always drawn as a template —
    // a non-template stand-in would be invisible against a matching menu bar.
    let bundled = Bundle.module.image(forResource: name)
    guard
      let image = bundled
        ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: "Perch")
    else { return nil }
    // 18 pt in the 22 pt bar, whatever the pixel size of the representation chosen.
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = bundled == nil ? true : isTemplate
    image.accessibilityDescription = "Perch"
    return image
  }

  /// The menu the status item drops: settings, the language switch, quit. Rebuilt
  /// whenever the language changes, since menu items keep the title they were born
  /// with. `current` is passed in rather than read from the store because the rebuild
  /// runs off the store's publisher, which fires before the property itself updates.
  private func buildStatusMenu(current: AppLanguage) -> NSMenu {
    let menu = NSMenu()
    let settings = NSMenuItem(
      title: L("設定…", "Settings…"),
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    settings.target = self
    menu.addItem(settings)

    let languageItem = NSMenuItem(title: L("言語", "Language"), action: nil, keyEquivalent: "")
    let languageMenu = NSMenu()
    for choice in AppLanguage.allCases {
      // Each language in its own name: the person who needs to switch must be able
      // to read the choice they are switching to.
      let entry = NSMenuItem(
        title: choice.nativeName,
        action: #selector(selectLanguage(_:)),
        keyEquivalent: ""
      )
      entry.target = self
      entry.representedObject = choice.rawValue
      entry.state = choice == current ? .on : .off
      languageMenu.addItem(entry)
    }
    languageItem.submenu = languageMenu
    menu.addItem(languageItem)

    menu.addItem(.separator())
    menu.addItem(
      withTitle: L("終了", "Quit"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    return menu
  }

  @objc private func selectLanguage(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let choice = AppLanguage(rawValue: raw)
    else { return }
    settingsStore.language = choice
  }

  @objc private func openSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = L("設定", "Settings")
    // The settings share the panel's face: black-based, whatever the system theme.
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(
      rootView: SettingsView(
        model: model,
        appearanceStore: appearanceStore,
        settingsStore: settingsStore,
        service: service
      )
    )
    window.isReleasedWhenClosed = false
    // Closing the window must end the rule editor's audition: SwiftUI's onDisappear
    // fires on tab switches but not when the window itself closes, so the close is
    // watched here. The window is built once and reused, so this registration also
    // runs once — reopening does not stack observers.
    settingsCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.model.endPreview(using: self.service)
      }
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow = window
  }
}

private struct NotchPanelBridge: View {
  @ObservedObject var model: AppModel
  @ObservedObject var appearanceStore: NotchAppearanceStore
  /// Observed for the language: a switch re-renders the open panel in place.
  @ObservedObject var settingsStore: AppSettingsStore
  let service: SessionService
  let presentation: NotchPresenter.Presentation
  let openSettings: () -> Void

  var body: some View {
    NotchPanelView(
      presentation: presentation,
      notchRect: NSScreen.withNotch?.notchGeometry?.rect ?? .zero,
      appearance: appearanceStore.appearance,
      displayMode: settingsStore.notchDisplayMode,
      model: model.panel,
      page: $model.page,
      pages: model.panelPages(using: service),
      transport: NowPlayingTransport(
        playPause: { model.nowPlayingPlayPause() },
        next: { model.nowPlayingNext() },
        previous: { model.nowPlayingPrevious() }
      ),
      openSettings: openSettings,
      retry: { await service.session.handle(.manualRetry) }
    )
    // The pages bake their strings when built; a new identity rebuilds them in the
    // newly chosen language.
    .id(settingsStore.language)
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
