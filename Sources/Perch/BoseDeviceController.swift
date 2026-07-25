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
  /// The audio output identity `activeAddress` was correlated from. The fast path is keyed
  /// on this rather than on the output's OUI: two paired Bose devices share an OUI, so an
  /// OUI-keyed cache stays "valid" when the output moves from one to the other and pins the
  /// session to the device that is no longer playing.
  private var correlatedOutput: String?
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
    correlatedOutput = nil
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
  /// not a Bose device. See `correlate(output:candidates:)` for how the two are matched.
  ///
  /// The IOBluetooth SDP scan runs here on the main actor deliberately: IOBluetooth
  /// delivers cached SDP off the calling thread's run loop, and a background thread has
  /// none, so `getServiceRecord` returns empty there. It reads cached records (no live
  /// query), so it does not block; only opening a channel is slow, and that is async.
  private func currentBoseControlAddress() -> String? {
    guard let output = currentOutputIdentifier() else {
      correlatedOutput = nil
      return nil
    }
    // Fast path: the output is the very one the live session was correlated from. The SDP
    // scan below does synchronous CoreBluetooth XPC, so it is skipped while the session
    // holds — only a change of audio *device* re-runs it, keeping the steady state off
    // that XPC path while still noticing a move between two Bose devices.
    if session != nil, let active = activeAddress, correlatedOutput == output {
      return active
    }
    let chosen = Self.correlate(output: output, candidates: bmapDeviceAddresses())
    correlatedOutput = chosen == nil ? nil : output
    return chosen
  }

  /// The current default audio output's device identifier, or `nil` when it is not
  /// Bluetooth. The raw string, so two Bose devices are told apart — never logged.
  private func currentOutputIdentifier() -> String? {
    switch audio.current() {
    case .identified(let device): return device.rawValue
    case .unidentifiedBluetooth(let uid): return uid
    case .other: return nil
    }
  }

  /// Picks the BMAP control address belonging to the device currently playing audio.
  ///
  /// A headset's audio address *is* its control address, so an exact match settles it. TWS
  /// earbuds are the case that cannot be settled that way — their audio rides one address
  /// and BMAP another — which is why correlation falls back to the OUI (the manufacturer
  /// block both share). With a single Bose device paired the OUI is enough; with several,
  /// it names them all, so the fallback then prefers the candidate sharing the longest
  /// address prefix with the output. A pair's two addresses are allocated together and
  /// agree well past the OUI, while a different Bose product diverges at it — so the
  /// earbuds in the ears win over the headphones in the bag.
  ///
  /// `nonisolated` and pure: the whole rule is exercised without Bluetooth.
  nonisolated static func correlate(output: String, candidates: [String]) -> String? {
    let outputOctets = addressOctets(of: output)
    guard outputOctets.count >= 3 else { return nil }
    let outputOUI = Array(outputOctets.prefix(3))

    var best: (address: String, shared: Int)?
    for candidate in candidates {
      let octets = addressOctets(of: candidate)
      guard Array(octets.prefix(3)) == outputOUI else { continue }
      let shared = zip(octets, outputOctets).prefix { $0 == $1 }.count
      // A full match is the device itself; nothing can beat it.
      if shared == outputOctets.count, shared == octets.count { return candidate }
      // Ties keep the earlier candidate: `bmapDeviceAddresses` orders connected first.
      if best == nil || shared > best!.shared { best = (candidate, shared) }
    }
    return best?.address
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
      // An opened channel that answers nothing is not a connection. Publishing `.ready`
      // here would show an empty panel over a link the next refresh has to tear down
      // anyway; failing now sends the loop straight back through connect().
      guard snapshot.isControllable else {
        Self.log.notice("bose connected but read nothing back; treating as unreachable")
        await teardown(keepingAddress: true)
        readout = Readout(status: .unreachable, modelName: nil, firmwareVersion: nil, battery: .unknown)
        return
      }
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
    if !keepingAddress {
      activeAddress = nil
      correlatedOutput = nil
    }
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
  ///
  /// `isControllable` answers one question only: did *this* call get an answer out of the
  /// device. It is therefore raised by live reads alone — never by a field carried over
  /// from an earlier snapshot. Counting the carried name and equalizer kept the flag true
  /// for the life of the connection, which made the caller's link-drop check dead code and
  /// left a dead session showing stale readings as `.ready`.
  private func readSnapshot(_ session: BoseSession, includingStable: Bool) async -> BoseDeviceSnapshot {
    var snap = BoseDeviceSnapshot()
    snap.acceptsWrites = true
    /// Whether any GET in this call came back parsed. The only evidence the link is alive.
    var readSomething = false

    if includingStable {
      snap.modelName = try? await readModelName(session)
      readSomething = readSomething || snap.modelName != nil
      snap.equalizerBands = try? await readEqualizer(session)
      readSomething = readSomething || snap.equalizerBands != nil
      modeList = (try? await readModeList(session)) ?? []
      readSomething = readSomething || !modeList.isEmpty
    } else {
      snap.modelName = snapshot.modelName
      snap.equalizerBands = snapshot.equalizerBands
    }

    // Battery [2.2]. A device that is busy can answer with no components at all, so an
    // empty list is still an answer: the read succeeded, which is what the flag tracks.
    if let battery = try? await readBatteryComponents(session) {
      snap.battery = battery
      readSomething = true
    }
    // Noise cancellation level [1.5] — the CNC range and current ambient/ANC balance.
    snap.noiseCancellation = try? await readNoiseCancellation(session)
    readSomething = readSomething || snap.noiseCancellation != nil

    // Audio modes (block 31). Ultra 2's live [31.10] answers a GET with
    // functionNotSupported, so the current ANC / spatial / wind state is read from the
    // *active mode's* [31.6] config — that also drives the mode list and selection.
    var currentMode: Int?
    if config.supportsModeBlock {
      currentMode = try? await readCurrentMode(session)
      readSomething = readSomething || currentMode != nil
      if let currentMode, let cfg = try? await readModeConfig(session, index: currentMode) {
        snap.liveNoiseControl = cfg.noiseControl
        readSomething = true
      }
      if !modeList.isEmpty {
        snap.audioModes = BoseAudioModes(modes: modeList, selectedSlot: currentMode)
      }
    }

    snap.isControllable = readSomething
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

  /// Reads every mode slot's [31.6] config and keeps the ones the device marks configured.
  /// The slots walked come from the model's declared preset + editable ranges, never a
  /// baked-in span, and an empty slot is recognised by its STATUS[4] flag rather than by
  /// its (localisable) placeholder name.
  private func readModeList(_ session: BoseSession) async throws -> [BoseAudioMode] {
    var modes: [BoseAudioMode] = []
    for index in config.modeSlots {
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

  /// The address octets, lowercased, from a string containing a Bluetooth address in any
  /// common separator/case. Capped at the six a BD_ADDR has, so trailing hex-looking
  /// fragments of a Core Audio device UID cannot extend it. `nonisolated` so the off-main
  /// SDP scan can call it.
  nonisolated static func addressOctets(of string: String) -> [String] {
    let octets = string.split(whereSeparator: { $0 == "-" || $0 == ":" })
      .map(String.init)
      .filter { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
      .map { $0.lowercased() }
    return Array(octets.prefix(6))
  }

  /// The first three address octets (the OUI / manufacturer block). Never the whole
  /// address, so it identifies the maker and not a device.
  nonisolated static func oui(of string: String) -> String? {
    let octets = addressOctets(of: string)
    guard octets.count >= 3 else { return nil }
    return octets.prefix(3).joined(separator: ":")
  }
}
