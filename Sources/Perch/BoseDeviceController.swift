import BoseCore
import BosePanel
import BoseSession
import BoseTransport
import Foundation
import TandemSession
import os

/// Owns the app's single Bose control path (stage 6).
///
/// Exactly one `BoseSession` at a time, because a BMAP device has one control channel.
/// From it this drives two things: a `Readout` the shared closed bar / General header show
/// (model name, battery, status), and a live `BosePanelModel` that reads every feature back
/// and turns the panel's gestures — noise control, ambient level, equalizer, immersive
/// audio — into device writes. The Sony session runs alongside untouched: it maps any
/// non-Sony output to "no device", and this only ever engages a device whose audio output
/// correlates to a BMAP control service, so the two never fight for a device.
///
/// It runs its own loop rather than doing work inside `AppModel.refresh`, so opening a
/// channel (seconds) never stalls the 500 ms Sony refresh. Blocking IOBluetooth SDP
/// enumeration is kept off the main actor; only the resulting values touch it.
@MainActor
final class BoseDeviceController: ObservableObject {
  struct Readout: Equatable {
    var status: DeviceSummary.Status
    var modelName: String?
    var firmwareVersion: String?
    var battery: BatteryLayout
  }

  /// The closed-bar / header summary, or `nil` when no Bose device is the audio output.
  @Published private(set) var readout: Readout?
  /// The live controls view-model, present exactly while a Bose device is connected.
  @Published private(set) var panelModel: BosePanelModel?

  var isActive: Bool { panelModel != nil }

  private let audio: any AudioOutputObserving
  private let openTimeout: Duration
  private let refreshInterval: Duration
  private let config: BoseDeviceConfig = .qcUltra2

  private var session: BoseSession?
  private var activeAddress: String?
  private var firmwareVersion: String?
  /// The last full snapshot, so a periodic partial re-read keeps name and equalizer.
  private var snapshot = BoseDeviceSnapshot()
  /// The audio-mode list (Quiet/Aware/Immersion/…), read once per connection; only the
  /// current selection and the active mode's preset are re-read each refresh.
  private var modeList: [BoseAudioMode] = []

  private var loopTask: Task<Void, Never>?

  private static let log = Logger(subsystem: "dev.perch.mac", category: "bose")

  init(
    audio: any AudioOutputObserving = AudioOutputObserver(),
    openTimeout: Duration = .seconds(12),
    refreshInterval: Duration = .seconds(4)
  ) {
    self.audio = audio
    self.openTimeout = openTimeout
    self.refreshInterval = refreshInterval
  }

  func start() {
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: self?.refreshInterval ?? .seconds(4))
      }
    }
  }

  func stop() async {
    loopTask?.cancel()
    loopTask = nil
    await teardown()
  }

  /// Stops the loop and hands the live session to the caller to close. Used at
  /// termination, where the main thread blocks on a bound wait and so cannot run the
  /// main-actor `stop()`; `BoseSession` is its own actor, closable from a detached task.
  func detachForTermination() -> BoseSession? {
    loopTask?.cancel()
    loopTask = nil
    let live = session
    session = nil
    activeAddress = nil
    panelModel = nil
    readout = nil
    return live
  }

  // MARK: - Loop

  private func tick() async {
    let target = currentBoseControlAddress()

    if target != activeAddress {
      await teardown()
      activeAddress = target
      guard let target else { return }
      await connect(to: target)
      return
    }

    if session != nil {
      await refreshSnapshot()
    } else if let target {
      await connect(to: target)
    }
  }

  /// The BMAP control address for the current audio output, or `nil` when the output is
  /// not a Bose device. Correlation is by OUI (the address's manufacturer block): the
  /// earbuds' audio address and their BMAP control address share it, while a Sony output
  /// or the speakers share it with no BMAP device — so idle earbuds are never woken and
  /// Sony is never disturbed.
  ///
  /// The IOBluetooth SDP scan runs here on the main actor deliberately: IOBluetooth
  /// delivers cached SDP off the calling thread's run loop, and a background thread has
  /// none, so `getServiceRecord` returns empty there. It reads cached records (no live
  /// query), so it does not block; only opening a channel is slow, and that is async.
  private func currentBoseControlAddress() -> String? {
    guard let outputOUI = currentOutputOUI() else { return nil }
    // Fast path: still connected to a device of this OUI. The SDP scan below does
    // synchronous CoreBluetooth XPC, so it is skipped while the session holds — only a
    // change of audio output re-runs it, keeping the steady state off that XPC path.
    if session != nil, let active = activeAddress, Self.oui(of: active) == outputOUI {
      return active
    }
    return bmapDeviceAddresses().first { Self.oui(of: $0) == outputOUI }
  }

  /// The OUI of the current default audio output, or `nil` when it is not Bluetooth.
  private func currentOutputOUI() -> String? {
    switch audio.current() {
    case .identified(let device): return Self.oui(of: device.rawValue)
    case .unidentifiedBluetooth(let uid): return Self.oui(of: uid)
    case .other: return nil
    }
  }

  // MARK: - Session lifecycle

  private func connect(to address: String) async {
    readout = Readout(status: .connecting, modelName: nil, firmwareVersion: nil, battery: .unknown)
    do {
      let opened = try await BmapRFCOMMChannelOpener(openTimeout: openTimeout).open(address: address)
      // Only the Ultra 2 family is byte-verified today; its config also drives the
      // provisional profile for unknown ids, so it is the safe default for a first read.
      let session = await BoseSession.start(opened: opened, config: config)
      try await session.connect()
      self.session = session

      firmwareVersion = try? await readFirmware(session)
      snapshot = await readSnapshot(session, includingStable: true)
      // The session talks the Ultra 2 dialect for every model in the family, but the panel
      // display config is chosen once the device has named itself: the earbuds withhold
      // wind reduction while the headphones keep it. Product ids are not yet plumbed from
      // SDP, so the device-reported product name is the only signal that tells them apart.
      panelModel = BosePanelModel(
        snapshot: snapshot,
        config: Self.displayConfig(forModelName: snapshot.modelName),
        session: session
      )
      publishReadout(status: .ready)
      Self.log.notice("bose connected: controllable")
    } catch {
      Self.log.notice("bose connect failed: \(String(describing: error), privacy: .public)")
      await teardown(keepingAddress: true)
      readout = Readout(status: .unreachable, modelName: nil, firmwareVersion: nil, battery: .unknown)
    }
  }

  private func refreshSnapshot() async {
    guard let session else { return }
    let fresh = await readSnapshot(session, includingStable: false)
    guard fresh.isControllable else {
      // A read failure means the link dropped; reconnect next tick.
      await teardown(keepingAddress: true)
      readout = Readout(status: .unreachable, modelName: nil, firmwareVersion: nil, battery: .unknown)
      return
    }
    // Carry the stable fields (name, equalizer) the partial read did not fetch.
    snapshot.battery = fresh.battery
    snapshot.noiseCancellation = fresh.noiseCancellation
    snapshot.liveNoiseControl = fresh.liveNoiseControl
    snapshot.audioModes = fresh.audioModes
    panelModel?.apply(snapshot: snapshot)
    publishReadout(status: .ready)
  }

  private func teardown(keepingAddress: Bool = false) async {
    if let session {
      await session.close()
    }
    session = nil
    panelModel = nil
    firmwareVersion = nil
    snapshot = BoseDeviceSnapshot()
    modeList = []
    if !keepingAddress { activeAddress = nil }
  }

  private func publishReadout(status: DeviceSummary.Status) {
    readout = Readout(
      status: status,
      modelName: snapshot.modelName,
      firmwareVersion: firmwareVersion,
      battery: Self.batteryLayout(from: snapshot.battery)
    )
  }

  // MARK: - Reading

  /// Reads the device into a snapshot. `includingStable` also fetches the fields that do
  /// not change while connected (model name, equalizer) — read once at connect and then
  /// carried forward, so the periodic refresh stays to battery and noise control.
  private func readSnapshot(_ session: BoseSession, includingStable: Bool) async -> BoseDeviceSnapshot {
    var snap = BoseDeviceSnapshot()
    snap.isControllable = true
    snap.acceptsWrites = true

    if includingStable {
      snap.modelName = try? await readModelName(session)
      snap.equalizerBands = try? await readEqualizer(session)
      modeList = (try? await readModeList(session)) ?? []
    } else {
      snap.modelName = snapshot.modelName
      snap.equalizerBands = snapshot.equalizerBands
    }

    // Battery [2.2]. Its absence is not a link failure (some reads race a device that is
    // busy), so an empty battery does not clear `isControllable`.
    if let battery = try? await readBatteryComponents(session) {
      snap.battery = battery
    }
    // Noise cancellation level [1.5] — the CNC range and current ambient/ANC balance.
    snap.noiseCancellation = try? await readNoiseCancellation(session)

    // Audio modes (block 31). Ultra 2's live [31.10] answers a GET with
    // functionNotSupported, so the current ANC / spatial / wind state is read from the
    // *active mode's* [31.6] config — that also drives the mode list and selection.
    var currentMode: Int?
    if config.supportsModeBlock {
      currentMode = try? await readCurrentMode(session)
      if let currentMode, let cfg = try? await readModeConfig(session, index: currentMode) {
        snap.liveNoiseControl = cfg.noiseControl
      }
      if !modeList.isEmpty {
        snap.audioModes = BoseAudioModes(modes: modeList, selectedSlot: currentMode)
      }
    }

    // If nothing at all came back, treat the link as gone.
    let gotAnything = !snap.battery.isEmpty || snap.noiseCancellation != nil
      || snap.liveNoiseControl != nil || snap.modelName != nil || snap.equalizerBands != nil
      || snap.audioModes != nil
    snap.isControllable = gotAnything
    return snap
  }

  /// The panel display config for a device that has named itself. Every Ultra 2 device
  /// shares the protocol config, so this differs from `config` only in the display axes
  /// that hardware, not the wire, decides — today just wind reduction, which the earbuds
  /// lack. An unread or unrecognised name keeps the headphones' full-feature default.
  private static func displayConfig(forModelName modelName: String?) -> BoseDeviceConfig {
    guard let name = modelName?.lowercased() else { return .qcUltra2 }
    let isEarbuds = name.contains("earbud") || name.contains("buds")
    return isEarbuds ? .qcUltra2Earbuds : .qcUltra2
  }

  private func readModelName(_ session: BoseSession) async throws -> String {
    let frame = try await session.request(try BmapProductInfo.deviceNameRequest())
    return try BmapProductInfo.parseDeviceName(frame)
  }

  private func readFirmware(_ session: BoseSession) async throws -> String {
    let frame = try await session.request(try BmapProductInfo.firmwareRequest())
    return try BmapProductInfo.parseFirmware(frame)
  }

  private func readBatteryComponents(_ session: BoseSession) async throws -> [BmapBatteryComponent] {
    let request = try BmapFrame(
      fblock: BmapFunctionAddress.battery.fblock,
      function: BmapFunctionAddress.battery.function,
      op: .get
    )
    let frame = try await session.request(request)
    return try BmapBattery.parse(frame, layout: config.batteryLayout)
  }

  private func readNoiseCancellation(_ session: BoseSession) async throws -> BmapNoiseCancellationReading {
    let frame = try await session.request(try BmapNoiseCancellationReader.readRequest())
    return try BmapNoiseCancellationReader.parse(frame)
  }

  /// Reads every mode slot's [31.6] config and keeps the configured (named) ones. Slots
  /// 0...10 cover the presets (Quiet/Aware/Immersion/Cinema) and the user slots; empty
  /// slots report the name "None" and are dropped.
  private func readModeList(_ session: BoseSession) async throws -> [BoseAudioMode] {
    var modes: [BoseAudioMode] = []
    for index in 0...10 {
      guard
        let frame = try? await session.request(try BmapAudioMode.configRequest(index: index)),
        let cfg = try? BmapAudioMode.parseConfig(frame), cfg.isConfigured
      else { continue }
      modes.append(BoseAudioMode(slot: cfg.index, name: cfg.name, isEditable: cfg.isUserEditable))
    }
    return modes
  }

  private func readCurrentMode(_ session: BoseSession) async throws -> Int {
    let frame = try await session.request(try BmapAudioMode.currentModeRequest())
    return try BmapAudioMode.parseCurrentMode(frame)
  }

  private func readModeConfig(_ session: BoseSession, index: Int) async throws -> BmapModeConfig {
    let frame = try await session.request(try BmapAudioMode.configRequest(index: index))
    return try BmapAudioMode.parseConfig(frame)
  }

  private func readEqualizer(_ session: BoseSession) async throws -> [BmapEqualizerBand] {
    let frame = try await session.request(try BmapEqualizer.readRequest())
    return try BmapEqualizer.parseBands(frame)
  }

  // MARK: - Helpers

  private static func batteryLayout(from components: [BmapBatteryComponent]) -> BatteryLayout {
    switch components.count {
    case 0:
      return .unknown
    case 1:
      return .single(components[0].percent)
    default:
      return .leftRight(
        left: components[0].percent,
        right: components[1].percent,
        charging: components.count >= 3 ? components[2].percent : nil
      )
    }
  }

  /// The first three address octets (the OUI / manufacturer block), lowercased, from a
  /// string containing a Bluetooth address in any common separator/case. Never the whole
  /// address. `nonisolated` so the off-main SDP scan can call it.
  nonisolated static func oui(of string: String) -> String? {
    let octets = string.split(whereSeparator: { $0 == "-" || $0 == ":" })
      .map(String.init)
      .filter { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    guard octets.count >= 3 else { return nil }
    return octets.prefix(3).map { $0.lowercased() }.joined(separator: ":")
  }
}
