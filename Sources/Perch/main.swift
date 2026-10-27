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

private enum AppModelWriteContext {
  @TaskLocal static var generation: UInt64?
}

@MainActor
final class AppModel: ObservableObject {
  @Published var panel = PanelModel()
  /// Opens on the home sheet — the first device sheet — with the common sheets to its
  /// left. Home whether or not a device is connected.
  @Published var page = PanelPages.homeIndex

  var pager = PanelPager(pageCount: PanelPages.count, index: PanelPages.homeIndex)

  /// System-wide spatial audio, driven from the common sheet. Device-independent.
  let spatial = SpatialAudioController()

  /// Camera head tracking, feeding the spatialiser's listener orientation. It follows
  /// the spatialiser's life: orientation goes nowhere without a running engine, and
  /// when the spatialiser goes off the camera must not keep running for nothing.
  let headTracking = HeadTrackingController()

  /// Whether the default output is headphones. Spatial audio is HRTF binaural — on
  /// speakers it falls apart — so the route gates the whole feature: no enabling on
  /// speakers, and pulling the headphones off turns it (and the camera, via the
  /// cascade below) straight off.
  let outputRoute = OutputRouteWatcher()
  private var headTrackingGate: AnyCancellable?
  private var routeGate: AnyCancellable?

  /// `dragSleep` times the drag pacers' waits; tests pass one they advance by hand.
  init(
    dragSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    writeSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    deviceWrites = DeviceWriteChain(sleep: writeSleep)
    levelDrag = DragWritePacer(sleep: dragSleep)
    bandDrag = DragWritePacer(sleep: dragSleep)
    headTracking.applyPose = { [weak self] orientation, distanceRatio in
      self?.spatial.updateListenerPose(orientation, distanceRatio: distanceRatio)
    }
    headTrackingGate = spatial.$isEnabled.sink { [weak self] enabled in
      if !enabled {
        self?.headTracking.setEnabled(false)
      }
    }
    routeGate = outputRoute.$isHeadphones.sink { [weak self] headphones in
      if !headphones {
        self?.spatial.setEnabled(false)
      }
    }
  }

  /// The parallel Bose control path. Runs its own loop; `refresh(from:cause:)` reads its
  /// `readout` and folds it into the panel when Sony has no device. Started/stopped by
  /// the AppDelegate alongside the Sony session.
  let bose = BoseDeviceController()

  /// Sends a change and refreshes from what the device actually reports back.
  ///
  /// The panel is not updated optimistically: on an unverified model the headset may
  /// do something other than what was asked, and showing the requested value would
  /// hide exactly the mismatch worth seeing.
  private let levelDrag: DragWritePacer
  /// While holding, the periodic refresh leaves the noise-control reading alone, so
  /// the device's not-yet-updated value cannot overwrite the level being dragged.
  private var levelAdjustment = AdjustmentGuard()
  /// While holding, the periodic refresh leaves the listening reading alone so a
  /// device that takes a moment to apply a mode change cannot snap the picker back.
  private var listeningAdjustment = AdjustmentGuard()

  /// Device writes land in the order they were asked — tiles, pickers, switches and
  /// drags alike; see `DeviceWriteChain`.
  private var deviceWrites: DeviceWriteChain
  /// Captured at intent time, including before a drag's debounce or auto-final.
  private var displayedEpoch: SessionEpoch?
  private var writeGeneration: UInt64 = 0

  /// A timed-out operation may eventually return. Its later automation steps and
  /// ownership commits must not overtake the writes the bounded chain let through.
  private func enqueueDeviceWrite(
    whileQueued: (@MainActor () -> Void)? = nil,
    onTimeout: (@MainActor () -> Void)? = nil,
    _ operation: @escaping @MainActor () async -> Void
  ) {
    var runningGeneration: UInt64?
    deviceWrites.enqueue(whileQueued: whileQueued, onTimeout: { [weak self] in
      if let self, runningGeneration == writeGeneration { writeGeneration &+= 1 }
      onTimeout?()
    }) { [weak self] in
      guard let self else { return }
      writeGeneration &+= 1
      runningGeneration = writeGeneration
      await AppModelWriteContext.$generation.withValue(writeGeneration) { await operation() }
    }
  }

  /// Waits until every device write asked so far has landed or been given up on.
  /// Used by tests and the bounded application termination sequence.
  func settleDeviceWrites() async {
    await deviceWrites.settled()
  }

  /// Queues a write to a guarded field. `send` puts it on the wire; what happens around
  /// it — sent at all, read back, guard lifted — is `GuardedWrite`'s decision, taken
  /// when the write's turn comes rather than when it was asked.
  ///
  /// The guard's lease is renewed as the write progresses — when it is queued (a drag's
  /// pacer queues seconds after the last report), each time the chain ahead of it
  /// advances, when it starts, and before its read-back — so it never lapses while the
  /// write is merely waiting; see `AdjustmentGuard`.
  private func enqueueGuardedWrite(
    _ field: ReferenceWritableKeyPath<AppModel, AdjustmentGuard>,
    token: Int,
    isFinal: Bool = true,
    using service: SessionService,
    send: @escaping @MainActor (SessionCoordinator) async -> Void
  ) {
    self[keyPath: field].renew(token)
    enqueueDeviceWrite(whileQueued: { [weak self] in self?[keyPath: field].renew(token) }) {
      [weak self] in
      guard let self else { return }
      let step = GuardedWrite.step(isFinal: isFinal, isCurrent: self[keyPath: field].isCurrent(token))
      guard step.sends else { return }
      defer { if step.liftsGuard { self[keyPath: field].end(token) } }
      self[keyPath: field].renew(token)
      await send(await service.session)
      guard step.liftsGuard else { return }
      self[keyPath: field].renew(token)
      await self.refresh(from: service, cause: .deviceWrite)
      self[keyPath: field].end(token)
    }
  }

  /// Await the current tail without keeping the main actor blocked.
  func waitForDeviceWrites() async {
    await deviceWrites.settled()
  }

  func applyListening(_ target: TandemListeningSelection, using service: SessionService) {
    guard let current = panel.listeningMode, let expectedEpoch = displayedEpoch else { return }
    let savedRoom: TandemListeningRoom
    if case .backgroundMusic(let room) = target { savedRoom = room } else { savedRoom = current.savedRoom }
    let token = listeningAdjustment.begin()
    panel.listeningMode = TandemListeningReading(
      features: current.features,
      selection: target,
      savedRoom: savedRoom
    )
    enqueueGuardedWrite(\.listeningAdjustment, token: token, using: service) {
      try? await $0.apply(listeningSelection: target, expectedEpoch: expectedEpoch)
    }
  }

  func applyNoiseControl(_ target: TandemNoiseControlState, using service: SessionService) {
    guard let expectedEpoch = displayedEpoch else { return }
    levelDrag.cancel()
    levelAdjustment.cancel()
    enqueueDeviceWrite { [weak self] in
      let session = await service.session
      try? await session.apply(noiseControl: target, expectedEpoch: expectedEpoch)
      await self?.refresh(from: service, cause: .deviceWrite)
    }
  }

  /// Called repeatedly while the level slider is dragged, and once more on release.
  ///
  /// The target is built from the current reading each time, so the release sends the
  /// value the finger actually settled on rather than a stale captured one.
  /// Intermediate values are debounced and sent as non-final; only the release — or,
  /// should none come, the value the drag stopped on — is read back and reflected in
  /// the panel. See `DragWritePacer`.
  func dragNoiseLevel(level: Int, isFinal: Bool, using service: SessionService) {
    guard let reading = panel.noiseControl, let expectedEpoch = displayedEpoch else { return }
    let clamped = reading.quantizedLevel(level, mode: reading.state.ambientMode)
    let target = TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: false,
      ambientMode: reading.state.ambientMode,
      ambientLevel: clamped,
      noiseAdaptation: reading.state.noiseAdaptation
    )
    // A release after the drag settled on its own, unmoved: that final already went
    // out, and its read-back lifts the guard. Skipped before any token is taken.
    if levelDrag.repeatsItsOwnFinal(isFinal: isFinal, valueUnchanged: reading.state == target) {
      return levelDrag.cancel()
    }

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

    levelDrag.report(isFinal: isFinal) { [weak self] isFinal in
      self?.writeLevel(target, isFinal: isFinal, token: token, epoch: expectedEpoch, using: service)
    }
  }

  /// Queues one level write behind the others. An intermediate value overtaken while
  /// it waited is dropped and a final always lands; why dropping is safe — every report
  /// that takes the token reaches the pacer, which writes it — is on `GuardedWrite`.
  private func writeLevel(
    _ target: TandemNoiseControlState, isFinal: Bool, token: Int, epoch: SessionEpoch,
    using service: SessionService
  ) {
    enqueueGuardedWrite(\.levelAdjustment, token: token, isFinal: isFinal, using: service) {
      try? await $0.apply(noiseControl: target, isFinal: isFinal, expectedEpoch: epoch)
    }
  }

  /// While holding, the periodic refresh leaves the equaliser reading alone so a band
  /// drag or preset change is not snapped back by the device's lagging value.
  private var equalizerAdjustment = AdjustmentGuard()
  private let bandDrag: DragWritePacer

  /// Selects a preset. The bands are left empty so the device loads the preset's own
  /// curve rather than being handed the current custom values.
  func applyEqualizerPreset(
    _ identifier: UInt8, bandSteps: [UInt8] = [], using service: SessionService
  ) {
    guard let reading = panel.equalizer, let expectedEpoch = displayedEpoch else { return }
    bandDrag.cancel()
    let token = equalizerAdjustment.begin()
    panel.equalizer = Self.equalizer(
      reading,
      selectedPreset: identifier,
      bandSteps: bandSteps.isEmpty ? reading.bandSteps : bandSteps.map(Int.init)
    )
    enqueueGuardedWrite(\.equalizerAdjustment, token: token, using: service) {
      try? await $0.apply(
        equalizerPreset: identifier, bandSteps: bandSteps, expectedEpoch: expectedEpoch)
    }
  }

  /// Called while a band is dragged and once on release. Editing a band lands on the
  /// device's custom preset; a device without one cannot be edited and is guarded out.
  func dragEqualizerBand(index: Int, step: Int, isFinal: Bool, using service: SessionService) {
    guard let reading = panel.equalizer, let presetIdentifier = reading.editablePresetIdentifier,
      let expectedEpoch = displayedEpoch
    else { return }
    let bands = reading.settingBand(index, toStep: step)
    let unchanged = reading.selectedPreset == presetIdentifier && reading.bandSteps == bands.map(Int.init)
    // As for the level: a release only repeating the drag's own final is not sent.
    if bandDrag.repeatsItsOwnFinal(isFinal: isFinal, valueUnchanged: unchanged) {
      return bandDrag.cancel()
    }
    let token = equalizerAdjustment.begin()
    panel.equalizer = Self.equalizer(
      reading,
      selectedPreset: presetIdentifier,
      bandSteps: bands.map(Int.init)
    )
    bandDrag.report(isFinal: isFinal) { [weak self] isFinal in
      self?.writeBands(
        bands, preset: presetIdentifier, isFinal: isFinal, token: token,
        epoch: expectedEpoch, using: service)
    }
  }

  /// Queues one band write, the way `writeLevel` queues a level.
  private func writeBands(
    _ bands: [UInt8], preset: UInt8, isFinal: Bool, token: Int, epoch: SessionEpoch,
    using service: SessionService
  ) {
    // The settled curve is remembered app-side as well as by the device, so the
    // user's own shape survives the device being adjusted from elsewhere.
    if isFinal { onBandsCommitted?(preset, bands.map(Int.init)) }
    enqueueGuardedWrite(\.equalizerAdjustment, token: token, isFinal: isFinal, using: service) {
      try? await $0.apply(
        equalizerPreset: preset, bandSteps: bands, isFinal: isFinal, expectedEpoch: epoch)
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

  /// Pulls what the session knows into the shape the panel draws. Only the periodic
  /// refresh asks the players; a write's read-back passes `.deviceWrite` and keeps the
  /// track shown — see `PanelRefreshCause`.
  func refresh(from service: SessionService, cause: PanelRefreshCause = .periodic) async {
    // Asked first: the Apple Events answer can take up to its deadline, and the
    // guarded panel fields below must be read and published without that wait
    // sitting between them.
    let nowPlaying = await cause.nowPlaying(queriesAllowed: playerQueriesAllowed) {
      await nowPlayingService.read()
    }
    let session = await service.session
    // One consistent hop: read piecemeal, an invalidation could land mid-read and show
    // a ready phase with no model name for a frame — which device-scoped rules read as
    // "no rule", flapping the settings. See SessionCoordinator.Snapshot.
    let snap = await session.snapshot
    if displayedEpoch != snap.epoch {
      displayedEpoch = snap.epoch
      previewHold = PreviewHold()
      ruleHold = nil
      pendingRuleRequest = nil
      levelDrag.cancel()
      bandDrag.cancel()
      levelAdjustment.cancel()
      equalizerAdjustment.cancel()
      listeningAdjustment.cancel()
      speakToChatAdjustment.cancel()
      sidetoneAdjustment.cancel()
    }
    let phase = snap.phase
    let fingerprint = snap.fingerprint
    let reason = snap.unsupportedReason
    let acceptsWrites = snap.acceptsWrites

    var next = PanelModel()
    next.summary.status = unreachableDebounce.present(
      DeviceSummary.status(for: phase, reason: reason)
    )
    next.summary.modelName = fingerprint?.modelName
    next.summary.firmwareVersion = fingerprint?.firmwareVersion
    next.summary.acceptsWrites = acceptsWrites

    let readings = snap.readings
    next.summary.codec = readings.codec?.description
    next.equalizer = equalizerAdjustment.isHolding() ? panel.equalizer : readings.equalizer
    next.listeningMode = listeningAdjustment.isHolding() ? panel.listeningMode : readings.listeningMode
    next.speakToChat = speakToChatAdjustment.isHolding() ? panel.speakToChat : readings.speakToChat
    next.sidetone = sidetoneAdjustment.isHolding() ? panel.sidetone : readings.sidetone
    // A drag in progress owns the level; the device's lagging value must not clobber
    // it mid-gesture.
    next.noiseControl = levelAdjustment.isHolding() ? panel.noiseControl : readings.noiseControl
    next.battery = Self.batteryLayout(for: fingerprint, readings: readings)

    // Bose runs in parallel. When Sony has no controllable device, a Bose device that is
    // the current audio output owns the summary and battery, so the shared closed bar and
    // the General tab show it instead of "対応機器なし". This is the one place ownership is
    // decided; see `PanelModel.foldingIn(bose:)`.
    next = next.foldingIn(bose: bose.readout)

    next.nowPlaying = nowPlaying.resolved(current: panel.nowPlaying)
    // A device that went away takes the editor preview with it: there is nothing left
    // to put back, and stale values must not land on the next device.
    if !next.summary.isControllable {
      previewHold = PreviewHold()
      // The rule's undo dies with the device for the same reason: what reconnects
      // may be a different device, and the old restore values belong to the old one.
      ruleHold = nil
      pendingRuleRequest = nil
    }

    // The same condition the bar widens by: its rising edge opens the five-second
    // announcement window the quiet mode shows.
    let hasContent = next.hasContent
    if hasContent, !hadContent {
      arrivalAnnounceUntil = ContinuousClock.now.advanced(by: .seconds(5))
      // A device arriving always turns spatial audio off. Arriving mid-capture — the
      // headset pulled over from another host above all — lands while the tap still
      // mutes the system and the engine is mid-rebuild, and the Mac ends up silent.
      // Connecting is a fresh start; spatial audio is explicit-on by design anyway
      // (the switch is never persisted), so it goes off and waits to be asked.
      spatial.setEnabled(false)
    }
    if !hasContent { arrivalAnnounceUntil = nil }
    hadContent = hasContent
    next.announcesArrival = arrivalAnnounceUntil.map { ContinuousClock.now < $0 } ?? false

    // The view collapses the device sheets into one status sheet while nothing is
    // readable (NotchPanelView.displayedPages); the pager must agree on the stop
    // count, or swipes dead-zone against stops that are not on screen — after a
    // disconnect from the fourth sheet, a swipe would "move" through pages that no
    // longer exist before anything visibly changed.
    // A Bose device declares its own feature set, so its readable stops come from the
    // sheets it actually has, not the fixed Sony count. The non-readable states collapse
    // to the common sheets plus one status sheet for either brand.
    let stops: Int
    if case .bose(let boseModel) = DeviceControls(panel: next, bosePanel: bose.panelModel),
      next.summary.isControllable {
      stops = BoseNotchLayout.pageCount(for: boseModel.state)
    } else {
      stops = Self.pagerStops(for: next.summary.status)
    }
    if pager.pageCount != stops {
      pager.setPageCount(stops)
      page = min(page, stops - 1)
    }

    if panel != next { panel = next }
  }

  /// How many stops the pager offers for a device state — the same shape
  /// `NotchPanelView.displayedPages` renders: every sheet with a readable device,
  /// else the common sheets plus the one status sheet.
  static func pagerStops(for status: DeviceSummary.Status) -> Int {
    switch status {
    case .ready, .unverified: PanelPages.count
    default: PanelPages.commonPageIDs.count + 1
    }
  }

  private let nowPlayingService = NowPlayingService(onAutomationDenied: {
    Task { @MainActor in AutomationPermission.shared.notePlayerDenied() }
  })

  func nowPlayingPlayPause() { nowPlayingService.playPause() }
  func nowPlayingNext() { nowPlayingService.next() }
  func nowPlayingPrevious() { nowPlayingService.previous() }

  /// Whether a re-injected headphone gesture should fall back to a system media key
  /// rather than scripting Spotify/Music. The ScriptingBridge path holds whenever the
  /// panel shows a track — playing *or paused*: a paused player is exactly the one a
  /// tap must be able to resume, and scripting needs no extra permission. Only with no
  /// scriptable track at all (a browser video, a game) does the system key take over.
  static func reinjectionUsesSystemKey(nowPlaying: PanelModel.NowPlaying?) -> Bool {
    nowPlaying == nil
  }

  // The headphone touch panel's re-injected transport. It scripts the player whose
  // track the notch shows (playing or paused — the pause/resume pair must land on the
  // same player), and with no such track re-issues the system media key the held
  // channel suppressed, which reaches a browser or any other player. Posting that key
  // needs Accessibility trust, asked for on first use with the system's own dialog.
  func reinjectPlayPause() {
    if Self.reinjectionUsesSystemKey(nowPlaying: panel.nowPlaying) {
      SystemMediaKey.requestTrustIfNeeded()
      SystemMediaKey.playPause.post()
    } else {
      nowPlayingService.playPause()
    }
  }

  func reinjectNext() {
    if Self.reinjectionUsesSystemKey(nowPlaying: panel.nowPlaying) {
      SystemMediaKey.requestTrustIfNeeded()
      SystemMediaKey.next.post()
    } else {
      nowPlayingService.next()
    }
  }

  func reinjectPrevious() {
    if Self.reinjectionUsesSystemKey(nowPlaying: panel.nowPlaying) {
      SystemMediaKey.requestTrustIfNeeded()
      SystemMediaKey.previous.post()
    } else {
      nowPlayingService.previous()
    }
  }

  private var speakToChatAdjustment = AdjustmentGuard()

  func applySpeakToChat(enabled: Bool, using service: SessionService) {
    guard let current = panel.speakToChat, let expectedEpoch = displayedEpoch else { return }
    let token = speakToChatAdjustment.begin()
    panel.speakToChat = Self.speakToChat(current, isEnabled: enabled)
    enqueueGuardedWrite(\.speakToChatAdjustment, token: token, using: service) {
      try? await $0.apply(speakToChatEnabled: enabled, expectedEpoch: expectedEpoch)
    }
  }

  func applySpeakToChatDetail(
    sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout,
    using service: SessionService
  ) {
    guard let current = panel.speakToChat, let expectedEpoch = displayedEpoch else { return }
    let token = speakToChatAdjustment.begin()
    panel.speakToChat = Self.speakToChat(current, sensitivity: sensitivity, timeout: timeout)
    enqueueGuardedWrite(\.speakToChatAdjustment, token: token, using: service) {
      try? await $0.apply(
        speakToChatSensitivity: sensitivity, timeout: timeout, expectedEpoch: expectedEpoch)
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
    guard let current = panel.sidetone, let expectedEpoch = displayedEpoch else { return }
    let token = sidetoneAdjustment.begin()
    panel.sidetone = SidetoneReading(
      slot: current.slot,
      snapshot: TandemGeneralSettingSnapshot(
        capability: current.snapshot.capability,
        isControlEnabled: current.snapshot.isControlEnabled,
        value: .boolean(enabled)
      )
    )
    enqueueGuardedWrite(\.sidetoneAdjustment, token: token, using: service) {
      try? await $0.apply(sidetoneEnabled: enabled, expectedEpoch: expectedEpoch)
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
  private enum RuleField: CaseIterable, Hashable { case noise, equalizer, listening }
  private struct RuleHold {
    let ruleID: UUID
    let epoch: SessionEpoch
    var changes = PreviewHold()
    /// Successful and no-op fields are evaluated once. Failed/missing fields may
    /// retry without capturing later manual adjustments to the other fields.
    var pending = Set(RuleField.allCases)
  }
  private var ruleHold: RuleHold?
  private struct RuleRequest {
    let sequence: UInt64
    let ruleID: UUID?
  }
  private var nextRuleRequest: UInt64 = 0
  private var pendingRuleRequest: RuleRequest?

  func playingNow() async -> NowPlayingService.PlayingAnswer { await nowPlayingService.playing() }

  /// Whether rules can act on the device that owns the panel right now. See
  /// `PanelModel.supportsRules`.
  var supportsRules: Bool { panel.supportsRules }

  /// Why the rule editor is withheld, for the notice shown in its place.
  var ruleUnavailableReason: RuleEditorUnavailableNotice.Reason { panel.ruleUnavailableReason }

  /// Applies the matched rule, first undoing whichever rule held before it.
  ///
  /// A hold is kept even when the rule changed nothing, so a source that is already
  /// set up right does not have later manual adjustments captured as its own.
  func applyRule(_ rule: SoundRule?, using service: SessionService) {
    // Sony actions cannot address the Bose owner. A previous Sony hold is released
    // through its epoch-bound transition, never interpreted as a Bose setting.
    let rule = supportsRules ? rule : nil
    if let pendingRuleRequest, pendingRuleRequest.ruleID == rule?.id { return }
    if pendingRuleRequest == nil {
      if rule == nil, ruleHold == nil { return }
      if let hold = ruleHold, hold.ruleID == rule?.id, hold.pending.isEmpty { return }
    }
    guard let expectedEpoch = displayedEpoch else { return }
    nextRuleRequest &+= 1
    let request = RuleRequest(sequence: nextRuleRequest, ruleID: rule?.id)
    pendingRuleRequest = request
    enqueueDeviceWrite(onTimeout: { [weak self] in
      if self?.pendingRuleRequest?.sequence == request.sequence { self?.pendingRuleRequest = nil }
    }) { [weak self] in
      guard let self else { return }
      defer {
        if pendingRuleRequest?.sequence == request.sequence { pendingRuleRequest = nil }
      }
      let session = await service.session
      guard await confirmedSnapshot(session, epoch: expectedEpoch) != nil else {
        await refresh(from: service, cause: .deviceWrite)
        return
      }
      if ruleHold?.epoch != expectedEpoch { ruleHold = nil }
      if let previous = ruleHold, previous.ruleID != rule?.id {
        ruleHold = nil
        await restore(previous.changes, session: session, epoch: expectedEpoch)
      }
      if let rule {
        var hold = ruleHold ?? RuleHold(ruleID: rule.id, epoch: expectedEpoch)
        await applyRuleFields(rule, hold: &hold, session: session, epoch: expectedEpoch)
        // An actor hop can replace the device at any stage, including the final
        // read-back. Never publish ownership from an abandoned session.
        if await confirmedSnapshot(session, epoch: expectedEpoch) != nil {
          ruleHold = hold
        }
      }
      await refresh(from: service, cause: .deviceWrite)
    }
  }

  private func confirmedSnapshot(
    _ session: SessionCoordinator, epoch: SessionEpoch
  ) async -> SessionCoordinator.Snapshot? {
    let snapshot = await session.snapshot
    return snapshot.epoch == epoch && snapshot.acceptsWrites
      && AppModelWriteContext.generation == writeGeneration ? snapshot : nil
  }

  private static func equalizerAllowed(_ snapshot: SessionCoordinator.Snapshot) -> Bool {
    let functions = Set(snapshot.fingerprint?.table1Functions.map(\.code) ?? [])
    return TandemListeningCatalog.features(forDeclared: functions).isEmpty
      || snapshot.readings.listeningMode?.selection == .standard
  }

  private func applyRuleFields(
    _ rule: SoundRule, hold: inout RuleHold, session: SessionCoordinator, epoch: SessionEpoch
  ) async {
    if hold.pending.contains(.noise) {
      if rule.noise == .keep { hold.pending.remove(.noise) }
      else if let snapshot = await confirmedSnapshot(session, epoch: epoch),
        let reading = snapshot.readings.noiseControl
      {
        if let target = Self.noiseTarget(rule.noise, reading), target != reading.state {
          do {
            try await session.apply(noiseControl: target, expectedEpoch: epoch)
            hold.changes.noise = (reading.state, target)
            hold.pending.remove(.noise)
          } catch { /* A transient failure leaves this field retryable. */ }
        } else { hold.pending.remove(.noise) }
      }
    }

    // Listening is established and read back before the dependent EQ action.
    if hold.pending.contains(.listening) {
      if rule.listening == .keep { hold.pending.remove(.listening) }
      else if let snapshot = await confirmedSnapshot(session, epoch: epoch),
        let reading = snapshot.readings.listeningMode
      {
        if let target = Self.listeningTarget(rule.listening, reading), target != reading.selection {
          do {
            try await session.apply(listeningSelection: target, expectedEpoch: epoch)
            hold.changes.listening = (reading.selection, target)
            hold.pending.remove(.listening)
          } catch { /* Do not send EQ on the strength of the requested mode. */ }
        } else { hold.pending.remove(.listening) }
      }
    }

    if hold.pending.contains(.equalizer) {
      guard let preset = rule.equalizerPreset else {
        hold.pending.remove(.equalizer)
        return
      }
      if rule.listening == .backgroundMusic || rule.listening == .cinema {
        hold.pending.remove(.equalizer)
        return
      }
      guard let snapshot = await confirmedSnapshot(session, epoch: epoch),
        let reading = snapshot.readings.equalizer, let previous = reading.selectedPreset
      else { return }
      guard Self.equalizerAllowed(snapshot) else {
        // A failed Standard request can be retried. Keeping a nonstandard mode
        // intentionally blocks EQ for the lifetime of this rule.
        if rule.listening == .keep { hold.pending.remove(.equalizer) }
        return
      }
      guard reading.presets.contains(where: { $0.identifier == preset }), previous != preset else {
        hold.pending.remove(.equalizer)
        return
      }
      do {
        try await selectPreset(preset, from: reading, session: session, epoch: epoch)
        hold.changes.equalizer = (previous, preset)
        hold.pending.remove(.equalizer)
      } catch {
        if Self.permanentPresetFailure(error) { hold.pending.remove(.equalizer) }
      }
    }
  }

  /// Undo only fields still holding our last confirmed value. Standard must be
  /// restored before EQ; when returning to Cinema/BGM, EQ must be restored first.
  private func restore(
    _ hold: PreviewHold, session: SessionCoordinator, epoch: SessionEpoch
  ) async {
    if let (previous, applied) = hold.noise,
      let snapshot = await confirmedSnapshot(session, epoch: epoch),
      snapshot.readings.noiseControl?.state == applied
    {
      try? await session.apply(noiseControl: previous, expectedEpoch: epoch)
    }
    if hold.listening?.previous == .standard {
      await restoreListening(hold, session: session, epoch: epoch)
    }
    if let (previous, applied) = hold.equalizer,
      let snapshot = await confirmedSnapshot(session, epoch: epoch),
      Self.equalizerAllowed(snapshot), snapshot.readings.equalizer?.selectedPreset == applied
    {
      try? await session.apply(equalizerPreset: previous, bandSteps: [], expectedEpoch: epoch)
    }
    if hold.listening?.previous != .standard {
      await restoreListening(hold, session: session, epoch: epoch)
    }
  }

  private func restoreListening(
    _ hold: PreviewHold, session: SessionCoordinator, epoch: SessionEpoch
  ) async {
    if let (previous, applied) = hold.listening,
      let snapshot = await confirmedSnapshot(session, epoch: epoch),
      snapshot.readings.listeningMode?.selection == applied
    {
      try? await session.apply(listeningSelection: previous, expectedEpoch: epoch)
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
  private enum PresetFailure: Error { case invalidRememberedBands }
  private func selectPreset(
    _ preset: UInt8, from reading: EqualizerReading,
    session: SessionCoordinator, epoch: SessionEpoch
  ) async throws {
    var bands: [UInt8] = []
    if reading.editablePresetIdentifier == preset, let steps = bandMemory?(preset) {
      bands = steps.compactMap(UInt8.init(exactly:))
      guard bands.count == steps.count else { throw PresetFailure.invalidRememberedBands }
    }
    try await session.apply(equalizerPreset: preset, bandSteps: bands, expectedEpoch: epoch)
  }

  private static func permanentPresetFailure(_ error: any Error) -> Bool {
    if error is PresetFailure { return true }
    guard let failure = error as? SessionCoordinator.WriteFailure else { return false }
    switch failure {
    case .invalidEqualizer, .undeclaredEqualizerPreset, .unsupported: return true
    default: return false
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
  private var pendingPreviewOperations = 0

  /// True while the audition holds anything. The rule watch loop reads this and
  /// stands down: a rule applied mid-preview would overwrite the value being judged
  /// and record it as the state to put back.
  var isPreviewing: Bool {
    pendingPreviewOperations > 0 || previewHold.noise != nil
      || previewHold.equalizer != nil || previewHold.listening != nil
  }

  private func enqueuePreview(
    using service: SessionService,
    _ operation: @escaping @MainActor (AppModel, SessionCoordinator, SessionEpoch) async -> Void
  ) {
    guard let expectedEpoch = displayedEpoch else { return }
    pendingPreviewOperations += 1
    var pending = true
    let finish: @MainActor () -> Void = { [weak self] in
      guard pending else { return }
      pending = false
      self?.pendingPreviewOperations -= 1
    }
    enqueueDeviceWrite(onTimeout: finish) { [weak self] in
      guard let self else { return }
      defer { finish() }
      let session = await service.session
      // Keep/end must still relinquish their hold while temporarily suspended.
      // Their restoration helper independently requires a writable session.
      if await session.snapshot.epoch == expectedEpoch,
        AppModelWriteContext.generation == writeGeneration
      {
        await operation(self, session, expectedEpoch)
      }
      await refresh(from: service, cause: .deviceWrite)
    }
  }

  func previewNoise(_ action: SoundRule.NoiseAction, using service: SessionService) {
    enqueuePreview(using: service) { model, session, epoch in
      if action == .keep {
        let hold = PreviewHold(noise: model.previewHold.noise)
        model.previewHold.noise = nil
        await model.restore(hold, session: session, epoch: epoch)
        return
      }
      guard let snapshot = await model.confirmedSnapshot(session, epoch: epoch),
        let reading = snapshot.readings.noiseControl,
        let target = Self.noiseTarget(action, reading), target != reading.state
      else { return }
      do {
        try await session.apply(noiseControl: target, expectedEpoch: epoch)
        guard await model.confirmedSnapshot(session, epoch: epoch) != nil else { return }
        let previous = model.previewHold.noise.flatMap {
          $0.applied == reading.state ? $0.previous : nil
        } ?? reading.state
        model.previewHold.noise = (previous, target)
      } catch { /* Keep ownership of the last confirmed preview on failure. */ }
    }
  }

  func previewEqualizerPreset(_ identifier: Int, using service: SessionService) {
    enqueuePreview(using: service) { model, session, epoch in
      if identifier < 0 {
        let hold = PreviewHold(equalizer: model.previewHold.equalizer)
        model.previewHold.equalizer = nil
        await model.restore(hold, session: session, epoch: epoch)
        return
      }
      guard let preset = UInt8(exactly: identifier),
        let snapshot = await model.confirmedSnapshot(session, epoch: epoch),
        Self.equalizerAllowed(snapshot),
        let reading = snapshot.readings.equalizer, let current = reading.selectedPreset,
        reading.presets.contains(where: { $0.identifier == preset }), current != preset
      else { return }
      do {
        try await model.selectPreset(preset, from: reading, session: session, epoch: epoch)
        guard await model.confirmedSnapshot(session, epoch: epoch) != nil else { return }
        let previous = model.previewHold.equalizer.flatMap {
          $0.applied == current ? $0.previous : nil
        } ?? current
        model.previewHold.equalizer = (previous, preset)
      } catch { /* Keep ownership of the last confirmed preview on failure. */ }
    }
  }

  func previewListening(_ action: SoundRule.ListeningAction, using service: SessionService) {
    enqueuePreview(using: service) { model, session, epoch in
      if action == .keep {
        let hold = PreviewHold(listening: model.previewHold.listening)
        model.previewHold.listening = nil
        await model.restore(hold, session: session, epoch: epoch)
        return
      }
      guard let snapshot = await model.confirmedSnapshot(session, epoch: epoch),
        let reading = snapshot.readings.listeningMode,
        let target = Self.listeningTarget(action, reading), target != reading.selection
      else { return }
      if target != .standard {
        // The editor resets EQ to Keep when selecting Cinema/BGM. Put its curve
        // back while Standard is still confirmed, before disabling EQ.
        let equalizer = PreviewHold(equalizer: model.previewHold.equalizer)
        model.previewHold.equalizer = nil
        await model.restore(equalizer, session: session, epoch: epoch)
      }
      guard await model.confirmedSnapshot(session, epoch: epoch) != nil else { return }
      do {
        try await session.apply(listeningSelection: target, expectedEpoch: epoch)
        guard await model.confirmedSnapshot(session, epoch: epoch) != nil else { return }
        let previous = model.previewHold.listening.flatMap {
          $0.applied == reading.selection ? $0.previous : nil
        } ?? reading.selection
        model.previewHold.listening = (previous, target)
      } catch { /* Keep ownership of the last confirmed preview on failure. */ }
    }
  }

  /// Ends the preview, putting back everything it changed — called when the rule is
  /// registered and when the editor goes away.
  func endPreview(using service: SessionService) {
    guard isPreviewing else { return }
    enqueuePreview(using: service) { model, session, epoch in
      let hold = model.previewHold
      model.previewHold = PreviewHold()
      await model.restore(hold, session: session, epoch: epoch)
    }
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
  private var refreshTask: Task<Void, Never>?
  private var permissionTask: Task<Void, Never>?
  private var rulesTask: Task<Void, Never>?
  private let termination = TerminationSequence()
  private let fullScreen = FullScreenMonitor()
  /// Looks for a newer release on GitHub. Lazy because it reads `settingsStore`; a bare
  /// `swift run` binary carries no version, so `SemanticVersion` is nil there and the
  /// checker quietly does nothing.
  private lazy var updateChecker = UpdateChecker(
    currentVersion: SemanticVersion(SupportIssue.appVersion),
    fetcher: GitHubReleaseFetcher(repository: SupportIssue.repository),
    settings: settingsStore
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = self.model
    let appearanceStore = self.appearanceStore
    let settingsStore = self.settingsStore
    let service = self.service
    let controller = NotchController(
      appearance: { appearanceStore.appearance },
      virtualNotchEnabled: { settingsStore.isVirtualNotchEnabled }
    ) { render in
      NotchPanelBridge(
        model: model,
        appearanceStore: appearanceStore,
        settingsStore: settingsStore,
        service: service,
        render: render,
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
    // The hover target follows the bar's drawn size by the very rule the view draws
    // by: while the bar stays bare — nothing to carry yet, or quiet mode with nothing
    // to announce — only the cutout itself reacts, not the hidden bar's side reaches.
    controller.isBarVisible = { [weak controller] in
      guard let controller else { return true }
      return NotchBarVisibility.isExtended(
        model: model.panel,
        isVirtual: controller.isVirtualNotch,
        displayMode: settingsStore.notchDisplayMode,
        presentation: controller.presentation
      )
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

    // Turning the virtual notch on or off does not change the geometry — no screen was
    // plugged or unplugged — so the screen-parameter observer never fires. Re-evaluate
    // the choice of notch directly. `dropFirst` skips the value `start()` already
    // reflected at launch; `refresh` is a no-op while the notch is switched off. The
    // controller reads the setting back through its closure, so the refresh waits for
    // the assignment to land — called from the publisher itself, it rebuilt against
    // the value being left.
    settingsStore.$isVirtualNotchEnabled
      .removeDuplicates()
      .dropFirst()
      .afterAssignment()
      .sink { [weak controller] _ in controller?.refresh() }
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

    // The Bose controller watches the audio output on its own loop and connects to a
    // Bose device when one becomes the output; the refresh below reads its result.
    model.bose.start()

    // When an update becomes available (or is dismissed), rebuild the menu so the
    // "download" item comes and goes. Only availability flips rebuild it — not the
    // checking→result churn — so the menu is not torn down mid-open on every poll.
    updateChecker.$status
      .map(\.availableRelease)
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self else { return }
        self.statusItem?.menu = self.buildStatusMenu(current: self.settingsStore.language)
      }
      .store(in: &cancellables)
    updateChecker.begin()

    refreshTask = Task {
      await service.start()
      while !Task.isCancelled {
        await model.refresh(from: service, cause: .periodic)
        try? await Task.sleep(for: .milliseconds(500))
      }
    }

    // A first launch has up to three permission prompts to show — Bluetooth, and
    // automation for each player — and firing them together buries one dialog under
    // another. Bluetooth (the session) goes first alone; the Apple-Events side — the
    // now-playing readout and the rule engine's queries — waits until the session
    // has a controllable device or ten seconds pass, whichever comes first.
    permissionTask = Task { [model] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !Task.isCancelled, ContinuousClock.now < deadline,
        !model.panel.summary.isControllable
      {
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !Task.isCancelled else { return }
      model.playerQueriesAllowed = true
    }

    // Holding the control channel open stops the headset from sending its touch-panel
    // play/skip gestures as media keys; it reports them over the channel instead. Re-
    // issue those through the same player transport the notch buttons use so the ear
    // controls keep working. Volume is left alone — the headset still applies that.
    let mediaGestures = MediaGestureForwarder(
      service: service,
      transport: .init(
        playPause: { [model] in model.reinjectPlayPause() },
        next: { [model] in model.reinjectNext() },
        previous: { [model] in model.reinjectPrevious() }
      )
    )
    mediaGestures.start()
    self.mediaGestures = mediaGestures

    // The automation watch on its own slow cadence: at most one Apple Events round
    // trip every two seconds, and only while rules exist and are switched on.
    model.bandMemory = { preset in settingsStore.customBandSteps["\(preset)"] }
    model.onBandsCommitted = { preset, steps in settingsStore.customBandSteps["\(preset)"] = steps }
    rulesTask = Task {
      while !Task.isCancelled {
        if !model.playerQueriesAllowed {
          // The launch-time permission serialisation above has not lifted the gate
          // yet; a rule pass now would fire the very automation prompts it delays.
        } else if model.isPreviewing {
          // The rule editor's audition owns the device. Neither applying a rule nor
          // releasing an existing hold may run under it: the engine freezes as it
          // stands and resumes once the preview ends.
        } else if settingsStore.isRulesEnabled, !settingsStore.rules.isEmpty {
          let rules = settingsStore.rules
          // The playing player is what the ears are on; while none plays, an app rule
          // matches by being frontmost and site rules speak through the visible tabs.
          let answer = await model.playingNow()
          // "Could not be asked" is not "nothing is playing": a hung player or a
          // pending prompt must not send the pass down to the browser tiers while
          // music actually plays. Judgement is withheld; the current hold stands.
          guard answer != .unknown else {
            try? await Task.sleep(for: .seconds(2))
            continue
          }
          var playing: NowPlayingService.Playing?
          if case .playing(let current) = answer { playing = current }
          let frontmost =
            playing == nil ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
          // Browsers are only asked while a rule could use the answer, and only while no
          // player is playing: the query is what surfaces the automation prompts and
          // reads the tabs. Hosts feed site rules; titles feed artist rules for the video
          // pages the player APIs cannot see. An app-only rule set justifies neither.
          let idle = playing == nil
          let hasSiteRule = rules.contains {
            if case .site = $0.trigger { return true }
            return false
          }
          let hasArtistRule = rules.contains {
            if case .artist = $0.trigger { return true }
            return false
          }
          let hosts = idle && hasSiteRule ? await SiteWatcher.visibleTabHosts() : []
          // Titles are trusted only from browsers that audibly play right now: an open
          // search page naming an artist is what is being read, not what is being heard.
          let titles =
            idle && hasArtistRule
            ? await SiteWatcher.visibleTabTitles(audible: AudibleProcesses.outputtingBundleIDs())
            : []
          guard !Task.isCancelled else { return }
          let context = RuleMatcher.Context(
            deviceModel: model.panel.summary.modelName,
            playingBundleID: playing?.bundleID,
            playingArtist: playing?.artist,
            frontmostBundleID: frontmost,
            browserHosts: hosts,
            browserTitles: titles
          )
          model.applyRule(RuleMatcher.match(rules, in: context), using: service)
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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if termination.hasCompleted { return .terminateNow }
    if !termination.hasStarted {
      refreshTask?.cancel()
      permissionTask?.cancel()
      rulesTask?.cancel()
      mediaGestures?.stop()
      model.playerQueriesAllowed = false
      model.endPreview(using: service)
      termination.begin(
        restore: { [model] in await model.waitForDeviceWrites() },
        stop: { [service, model] in
          // The main actor remains available during terminateLater, so Bose can
          // cancel and await its in-flight tick before closing its session too.
          async let sonyStop: Void = service.stop()
          await model.bose.stop()
          await sonyStop
        },
        completion: { sender.reply(toApplicationShouldTerminate: true) }
      )
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    refreshTask?.cancel()
    permissionTask?.cancel()
    rulesTask?.cancel()
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    mediaGestures?.stop()
    updateChecker.stop()
    // The camera must not outlive the app either; stopping the tracker first also
    // spares one pointless "face lost" fade while the spatializer is torn down.
    model.headTracking.setEnabled(false)
    // The spatializer mutes the system's own output while it runs; it must give that
    // back before the process dies, or the quit leaves the Mac silent. setEnabled(false)
    // tears the tap down synchronously.
    model.spatial.setEnabled(false)
    controller?.stop()
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
    //
    // Read from the app bundle, never `Bundle.module`. SwiftPM's accessor for an
    // *executable* target looks in exactly two places — `Bundle.main.bundleURL`
    // (the .app's own directory, not its Resources) and the absolute build path
    // baked in at compile time — and calls `fatalError` when both miss. Packaged
    // into an .app the first always misses, so the app ran only on a machine that
    // still had the build tree at that exact path: on every other Mac it crashed
    // here at launch. `Bundle.main` finds what package_app.sh installs, and a miss
    // falls through to the symbol below instead of killing the process.
    let bundled = Bundle.main.image(forResource: name)
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

    // Surfaced only while an update is waiting, so someone who never opens settings
    // still learns a new version exists and can reach the download in one click.
    if case .available(let info) = updateChecker.status {
      let update = NSMenuItem(
        title: L("アップデートがあります…", "Update available…"),
        action: #selector(openUpdateDownload(_:)),
        keyEquivalent: ""
      )
      update.target = self
      update.representedObject = info.bestDownloadURL
      menu.addItem(update)
      menu.addItem(.separator())
    }

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

  @objc private func openUpdateDownload(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
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
        updateChecker: updateChecker,
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
  /// The state and geometry the controller resolved, including a notch it synthesised
  /// on a screen with no cutout — the panel reads the cutout from here rather than
  /// asking `NSScreen`, which does not know about a virtual notch.
  let render: NotchRender
  let openSettings: () -> Void

  var body: some View {
    NotchPanelView(
      presentation: render.presentation,
      notchRect: render.notchRect,
      isVirtual: render.isVirtual,
      appearance: appearanceStore.appearance,
      displayMode: settingsStore.notchDisplayMode,
      model: model.panel,
      page: $model.page,
      pages: notchPages,
      transport: NowPlayingTransport(
        playPause: { model.nowPlayingPlayPause() },
        next: { model.nowPlayingNext() },
        previous: { model.nowPlayingPrevious() }
      ),
      openSettings: openSettings,
      retry: { await service.session.handle(.manualRetry) }
    )
    // The Bose sheets observe the Bose model themselves, so a drag redraws them even
    // though this bridge does not; the identity below still rebuilds on a language switch.
    // The pages bake their strings when built; a new identity rebuilds them in the
    // newly chosen language.
    .id(settingsStore.language)
  }

  /// The sheets the notch shows: a connected Bose device brings its own (equalizer, modes,
  /// spatial/sidetone), matching the General tab; otherwise the Sony sheets are shown, which
  /// also carry the common spatial sheet when no device is connected at all.
  private var notchPages: [PanelPage] {
    // The same decision the General tab draws from, so the two show one brand.
    let controls = DeviceControls(panel: model.panel, bosePanel: model.bose.panelModel)
    if case .bose(let boseModel) = controls {
      return model.bosePanelPages(boseModel)
    }
    return model.panelPages(using: service)
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
