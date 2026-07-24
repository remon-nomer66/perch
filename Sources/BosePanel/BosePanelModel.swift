import BoseCore
import BoseSession
import Combine
import Foundation
import SwiftUI

/// Guards one panel field against a periodic refresh while a write is in flight, so the
/// device's not-yet-updated value cannot snap a control back mid-gesture. Each `begin`
/// issues a fresh token; only the latest token's holder may lift the guard. A direct copy
/// of the Sony `AppModel`'s guard — the set→poll discipline is the same on both brands.
struct BoseAdjustmentGuard {
  private(set) var isHolding = false
  private var generation = 0

  mutating func begin() -> Int {
    generation += 1
    isHolding = true
    return generation
  }

  mutating func end(_ token: Int) {
    if generation == token { isHolding = false }
  }

  mutating func cancel() {
    generation += 1
    isHolding = false
  }
}

/// The Bose panel's view-model: it holds the last snapshot, projects it onto the panel
/// state the view renders, and turns UI gestures into BoseSession commands.
///
/// It follows the Sony `AppModel`'s set→poll thinking: a write is sent, then the panel is
/// reconciled with what the device actually reports back rather than the value that was
/// asked for — on an unverified model the two can differ, and that difference is exactly
/// what is worth seeing. Gestures update the local snapshot at once for responsiveness (a
/// guard keeps a refresh from overwriting the field), then the confirmed device value wins
/// when the round trip returns.
///
/// The session is optional so the panel is fully usable without hardware (previews and
/// tests): with no session the optimistic snapshot update stands, which is all this stage
/// needs. Stage 6 supplies the live session and the periodic refresh that reads every
/// feature back.
@MainActor
public final class BosePanelModel: ObservableObject {
  @Published public private(set) var state: BosePanelState
  @Published public var page: Int = 0

  private var snapshot: BoseDeviceSnapshot
  private let config: BoseDeviceConfig
  private let session: BoseSession?

  private var cncAdjustment = BoseAdjustmentGuard()
  private var equalizerAdjustment = BoseAdjustmentGuard()
  private var cncDrag: Task<Void, Never>?
  private var bandDrags: [UInt8: Task<Void, Never>] = [:]

  public init(
    snapshot: BoseDeviceSnapshot = BoseDeviceSnapshot(),
    config: BoseDeviceConfig,
    session: BoseSession? = nil
  ) {
    self.snapshot = snapshot
    self.config = config
    self.session = session
    self.state = BosePanelState.project(from: snapshot, config: config)
  }

  /// Replaces the snapshot and re-projects. A guarded field is left untouched so a refresh
  /// arriving mid-gesture cannot overwrite what the finger is holding.
  public func apply(snapshot new: BoseDeviceSnapshot) {
    var merged = new
    if cncAdjustment.isHolding {
      merged.noiseCancellation = snapshot.noiseCancellation
      merged.liveNoiseControl = snapshot.liveNoiseControl
    }
    if equalizerAdjustment.isHolding {
      merged.equalizerBands = snapshot.equalizerBands
    }
    snapshot = merged
    reproject()
  }

  /// The bundle of gesture handlers the pages call.
  public var actions: BosePanelActions {
    BosePanelActions(
      dragCNCStrength: { [weak self] strength, isFinal in
        self?.dragCNCStrength(strength, isFinal: isFinal)
      },
      setANC: { [weak self] on in self?.setANC(on) },
      setWind: { [weak self] on in self?.setWind(on) },
      dragEqualizerBand: { [weak self] band, value, isFinal in
        self?.dragEqualizerBand(bandId: band, value: value, isFinal: isFinal)
      },
      selectMode: { [weak self] slot in self?.selectMode(slot) },
      setSpatial: { [weak self] spatial in self?.setSpatial(spatial) },
      setSidetone: { [weak self] level in self?.setSidetone(level) }
    )
  }

  private func reproject() {
    state = BosePanelState.project(from: snapshot, config: config)
  }

  // MARK: - Noise control ([31.10] + [1.5])

  /// A CNC drag, in UI strength terms. The strength is inverted back to the wire value
  /// (`BoseCNCState.wireValue(forStrength:)`) — the one place the wire's 0 = quietest
  /// convention re-enters — then both readings that carry a CNC value are updated so the
  /// slider stays put whichever the projection prefers.
  public func dragCNCStrength(_ strength: Int, isFinal: Bool) {
    guard let cnc = state.cnc else { return }
    let wire = BoseCNCState.wireValue(forStrength: strength, in: cnc.range)
    let token = cncAdjustment.begin()

    snapshot = snapshot.settingCNCWire(wire)
    reproject()

    cncDrag?.cancel()
    cncDrag = Task { [weak self] in
      if !isFinal {
        try? await Task.sleep(for: .milliseconds(90))
        if Task.isCancelled { return }
      }
      await self?.sendLiveNoiseControl(final: isFinal, token: token)
    }
  }

  public func setANC(_ on: Bool) {
    guard state.ancEnabled != nil else { return }
    let token = cncAdjustment.begin()
    snapshot = snapshot.settingLive { $0.withANC(on) }
    reproject()
    Task { [weak self] in await self?.sendLiveNoiseControl(final: true, token: token) }
  }

  public func setWind(_ on: Bool) {
    guard state.windReduction != nil else { return }
    let token = cncAdjustment.begin()
    snapshot = snapshot.settingLive { $0.withWind(on) }
    reproject()
    Task { [weak self] in await self?.sendLiveNoiseControl(final: true, token: token) }
  }

  public func setSpatial(_ spatial: BmapNoiseControlSetting.Spatial) {
    guard state.spatial != nil else { return }
    let token = cncAdjustment.begin()
    snapshot = snapshot.settingLive { $0.withSpatial(spatial) }
    reproject()
    Task { [weak self] in await self?.sendLiveNoiseControl(final: true, token: token) }
  }

  /// Sends the whole [31.10] five-byte state and reconciles the panel with the device's
  /// echo. Requires a full live-control reading to build the frame safely — the write sets
  /// CNC, ANC, wind, and spatial together, so a partial state would guess the others.
  private func sendLiveNoiseControl(final: Bool, token: Int) async {
    defer { if final { cncAdjustment.end(token) } }
    guard let session, let live = snapshot.liveNoiseControl else { return }
    guard let frame = try? BmapNoiseControlLiveWrite.writeRequest(live) else { return }
    // The SETGET echoes the applied state (STATUS/RESULT at [31.10]); that echo is the
    // confirmation the set→poll discipline reconciles against.
    guard let response = try? await session.request(frame),
      let confirmed = try? BmapNoiseControlLiveWrite.parse(response)
    else { return }
    if final {
      snapshot = snapshot.settingLive { _ in confirmed }
      reproject()
    }
  }

  // MARK: - Equalizer ([1.7])

  public func dragEqualizerBand(bandId: UInt8, value: Int, isFinal: Bool) {
    guard state.equalizer != nil else { return }
    let token = equalizerAdjustment.begin()
    snapshot = snapshot.settingEqualizerBand(bandId: bandId, value: value)
    reproject()

    bandDrags[bandId]?.cancel()
    bandDrags[bandId] = Task { [weak self] in
      if !isFinal {
        try? await Task.sleep(for: .milliseconds(90))
        if Task.isCancelled { return }
      }
      await self?.sendEqualizerBand(bandId: bandId, value: value, final: isFinal, token: token)
    }
  }

  private func sendEqualizerBand(bandId: UInt8, value: Int, final: Bool, token: Int) async {
    defer { if final { equalizerAdjustment.end(token) } }
    guard let session else { return }
    let range = snapshot.equalizerBands?.first { $0.bandId == bandId }
      .map { $0.minimum...$0.maximum }
    guard
      let write = try? BmapEqualizer.setRequest(bandId: bandId, value: value, range: range),
      let readBack = try? BmapEqualizer.readRequest()
    else { return }
    // Write then read the value back until the device reports it — the write's own echo
    // can lie on an unverified device, so a separate GET confirms what stuck.
    let confirmed = try? await session.writeThenPoll(
      write: write,
      readBack: readBack,
      isApplied: { frame in
        guard let bands = try? BmapEqualizer.parseBands(frame) else { return false }
        return bands.contains { $0.bandId == bandId && $0.current == value }
      }
    )
    if final, let confirmed, let bands = try? BmapEqualizer.parseBands(confirmed) {
      snapshot.equalizerBands = bands
      reproject()
    }
  }

  // MARK: - Modes ([31.6]) and sidetone — optimistic only for now

  /// Selects an audio mode via [31.3]. Updates the panel optimistically for
  /// responsiveness, then sends the switch; the periodic refresh reconciles the current
  /// mode and its noise-control preset (CNC / spatial / ANC) against the device.
  public func selectMode(_ slot: Int) {
    guard let modes = snapshot.audioModes else { return }
    snapshot.audioModes = BoseAudioModes(modes: modes.modes, selectedSlot: slot)
    reproject()
    Task { [weak self] in await self?.sendModeSelect(slot) }
  }

  private func sendModeSelect(_ slot: Int) async {
    guard let session else { return }
    guard let frame = try? BmapAudioMode.selectModeRequest(index: slot) else { return }
    // The START answers with a RESULT at [31.3]; success is enough — the refresh reads
    // the new current mode and its config back.
    _ = try? await session.request(frame)
  }

  /// Sets the sidetone level. Its wire mapping is not yet reverse-engineered, so this is
  /// optimistic; stage 6 adds the builder and the read-back.
  public func setSidetone(_ level: BoseSidetone) {
    guard snapshot.sidetone != nil else { return }
    snapshot.sidetone = level
    reproject()
  }
}

// MARK: - Immutable snapshot updates

extension BoseDeviceSnapshot {
  /// Returns a copy with the CNC value set on whichever readings carry it, so the two
  /// possible sources stay consistent after a drag.
  func settingCNCWire(_ wire: Int) -> BoseDeviceSnapshot {
    var copy = self
    if let reading = noiseCancellation {
      copy.noiseCancellation = BmapNoiseCancellationReading(
        currentStep: wire,
        maximumStep: reading.maximumStep,
        isEnabled: reading.isEnabled,
        rawFlags: reading.rawFlags
      )
    }
    if let live = liveNoiseControl {
      copy.liveNoiseControl = BmapNoiseControlSetting(
        cnc: wire,
        spatial: live.spatial,
        windBlock: live.windBlock,
        ancEnabled: live.ancEnabled
      )
    }
    return copy
  }

  /// Returns a copy with the live control transformed, if one has been read.
  func settingLive(
    _ transform: (BmapNoiseControlSetting) -> BmapNoiseControlSetting
  ) -> BoseDeviceSnapshot {
    guard let live = liveNoiseControl else { return self }
    var copy = self
    copy.liveNoiseControl = transform(live)
    return copy
  }

  /// Returns a copy with one equalizer band's value replaced.
  func settingEqualizerBand(bandId: UInt8, value: Int) -> BoseDeviceSnapshot {
    guard let bands = equalizerBands else { return self }
    var copy = self
    copy.equalizerBands = bands.map { band in
      band.bandId == bandId
        ? BmapEqualizerBand(
          bandId: band.bandId, minimum: band.minimum, maximum: band.maximum, current: value
        )
        : band
    }
    return copy
  }
}

extension BmapNoiseControlSetting {
  func withANC(_ on: Bool) -> BmapNoiseControlSetting {
    BmapNoiseControlSetting(cnc: cnc, spatial: spatial, windBlock: windBlock, ancEnabled: on)
  }

  func withWind(_ on: Bool) -> BmapNoiseControlSetting {
    BmapNoiseControlSetting(cnc: cnc, spatial: spatial, windBlock: on, ancEnabled: ancEnabled)
  }

  func withSpatial(_ spatial: Spatial) -> BmapNoiseControlSetting {
    BmapNoiseControlSetting(cnc: cnc, spatial: spatial, windBlock: windBlock, ancEnabled: ancEnabled)
  }
}
