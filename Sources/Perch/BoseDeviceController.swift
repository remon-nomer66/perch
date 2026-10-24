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
/// audio — into device writes. The Sony session runs alongside untouched, and the two can
/// both be live at once — it targets any identified output, whatever the brand, while this
/// engages a device whose audio output correlates to a BMAP control service. Which of them
/// owns the screens is therefore decided in one place, `PanelModel.foldingIn(bose:)`.
///
/// It runs its own loop rather than doing work inside `AppModel.refresh`, so opening a
/// channel (seconds) never stalls the 500 ms Sony refresh. The loop polls, and a switch of
/// the default output to another device wakes it early. Blocking IOBluetooth SDP
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
  /// `.ready` only while `panelModel` is live: every teardown clears it.
  @Published private(set) var readout: Readout?
  /// The live controls view-model, present exactly while a Bose device is connected.
  @Published private(set) var panelModel: BosePanelModel?

  var isActive: Bool { panelModel != nil }

  private let audio: any AudioOutputObserving
  private let devices: any BmapDeviceAccess
  private let openTimeout: Duration
  private let refreshInterval: Duration
  /// The connected model's config, resolved from the product id it announces over SDP at
  /// every connect. `BoseCatalog`'s provisional Ultra 2 profile until a device names
  /// itself — and again for any id the catalog does not know.
  private var config: BoseDeviceConfig = BoseCatalog.fallbackConfig

  private var session: BoseSession?
  private var activeAddress: String?
  /// The audio output identity `activeAddress` was correlated from. The fast path is keyed
  /// on this rather than on the output's OUI: two paired Bose devices share an OUI, so an
  /// OUI-keyed cache stays "valid" when the output moves from one to the other and pins the
  /// session to the device that is no longer playing.
  private var correlatedOutput: String?
  /// BMAP addresses that would not open, and the audio output they were tried against.
  ///
  /// A paired Bose product can publish more than one BMAP address — a probe of QC Ultra
  /// Earbuds found two, and only the second answered; the first timed out. Correlation
  /// cannot tell those apart from the address alone, so the loop rotates: an address that
  /// fails to open is set aside and the next candidate is tried, until one answers or the
  /// list is exhausted and the whole set is reconsidered.
  private var failedAddresses: Set<String> = []
  private var failedAddressesOutput: String?
  private var firmwareVersion: String?
  /// The last full snapshot, so a periodic partial re-read keeps name and equalizer.
  private var snapshot = BoseDeviceSnapshot()
  /// The audio-mode list (Quiet/Aware/Immersion/…), read once per connection; only the
  /// current selection and the active mode's preset are re-read each refresh.
  private var modeList: [BoseAudioMode] = []

  private var loopTask: Task<Void, Never>?
  /// Listens for default-output changes, so a switch is acted on when it is reported.
  private var outputTask: Task<Void, Never>?
  /// The wait between two ticks while it runs; cancelled to wake the loop early.
  private var pauseTask: Task<Void, Never>?
  /// A switch reported mid-tick: the pause after it is skipped rather than slept through.
  private var wakePending = false

  private static let log = Logger(subsystem: "dev.perch.mac", category: "bose")

  init(
    audio: any AudioOutputObserving = AudioOutputObserver(),
    devices: any BmapDeviceAccess = LiveBmapDeviceAccess(),
    openTimeout: Duration = .seconds(12),
    refreshInterval: Duration = .seconds(4)
  ) {
    self.audio = audio
    self.devices = devices
    self.openTimeout = openTimeout
    self.refreshInterval = refreshInterval
  }

  func start() {
    guard loopTask == nil else { return }
    // Taken before `start()`, which publishes the current output to whoever is listening.
    let changes = audio.changes
    audio.start()
    outputTask = Task { [weak self] in
      for await output in changes {
        self?.outputChanged(to: output)
      }
    }
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.tick()
        await self.pause()
      }
    }
  }

  func stop() async {
    loopTask?.cancel()
    loopTask = nil
    stopWatchingOutput()
    await teardown()
  }

  /// Stops the loop and hands the live session to the caller to close. Used at
  /// termination, where the main thread blocks on a bound wait and so cannot run the
  /// main-actor `stop()`; `BoseSession` is its own actor, closable from a detached task.
  func detachForTermination() -> BoseSession? {
    loopTask?.cancel()
    loopTask = nil
    stopWatchingOutput()
    let live = session
    session = nil
    activeAddress = nil
    correlatedOutput = nil
    panelModel = nil
    readout = nil
    return live
  }

  // MARK: - Loop

  /// One pass of the loop. Internal rather than private so a test can step the loop
  /// itself instead of racing its timer.
  func tick() async {
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

  /// Waits out the refresh interval between two ticks — or less, when a switch is
  /// reported meanwhile (`outputChanged`).
  private func pause() async {
    guard !wakePending else {
      wakePending = false
      return
    }
    let pause = Task<Void, Never> { [refreshInterval] in
      try? await Task.sleep(for: refreshInterval)
    }
    pauseTask = pause
    // The loop's own cancellation must end the wait too: `pause` is not its child.
    await withTaskCancellationHandler {
      await pause.value
    } onCancel: {
      pause.cancel()
    }
    pauseTask = nil
  }

  /// A reported change of the default output.
  ///
  /// The poll alone re-correlates a switch only when it next comes round, and until then
  /// the panel keeps driving the device that stopped playing — a gesture in that window
  /// writes to headphones nobody is listening to. So a switch to another device wakes the
  /// loop now: the pause in progress is cut short, or, mid-tick, the next one is skipped.
  private func outputChanged(to output: AudioOutput) {
    guard Self.isSwitch(to: output, awayFrom: correlatedOutput) else { return }
    if let pauseTask {
      pauseTask.cancel()
    } else {
      wakePending = true
    }
  }

  private func stopWatchingOutput() {
    outputTask?.cancel()
    outputTask = nil
    audio.stop()
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
    // Failures belong to the output they happened under; a different device starts clean.
    if failedAddressesOutput != output {
      failedAddresses.removeAll()
      failedAddressesOutput = output
    }

    let candidates = devices.candidates()
    var chosen = Self.correlate(
      output: output,
      candidates: candidates.filter { !failedAddresses.contains(Self.normalized($0.address)) }
    )
    if chosen == nil, !failedAddresses.isEmpty {
      // Every candidate has failed at least once. Forget that and start the rotation
      // again rather than go silent for good: a bud that was in its case may be out now.
      failedAddresses.removeAll()
      chosen = Self.correlate(output: output, candidates: candidates)
    }
    correlatedOutput = chosen == nil ? nil : output
    return chosen
  }

  /// An address in one canonical form, so the same device is recognised however the
  /// separators and case came out of IOBluetooth or Core Audio.
  nonisolated static func normalized(_ address: String) -> String {
    addressOctets(of: address).joined(separator: ":")
  }

  private func currentOutputIdentifier() -> String? {
    Self.identifier(of: audio.current())
  }

  /// The device identifier of an audio output, or `nil` when it is not Bluetooth. The
  /// raw string, so two Bose devices are told apart — never logged.
  nonisolated static func identifier(of output: AudioOutput) -> String? {
    switch output {
    case .identified(let device): return device.rawValue
    case .unidentifiedBluetooth(let uid): return uid
    case .other: return nil
    }
  }

  /// Whether a reported output names a device other than the one the session was
  /// correlated from — the only change worth waking the loop for. Core Audio reports the
  /// same output again too, and each wake costs a synchronous SDP scan or a reopen.
  nonisolated static func isSwitch(to output: AudioOutput, awayFrom correlated: String?) -> Bool {
    identifier(of: output) != correlated
  }

  // MARK: - Session lifecycle

  private func connect(to address: String) async {
    readout = Readout(status: .connecting, modelName: nil, firmwareVersion: nil, battery: .unknown)
    do {
      // The model decides the dialect — QC35 answers nothing until it receives the [0.1]
      // init, reports a one-byte battery, and has no block 31 — so the config is resolved
      // from the announced product id *before* the session starts. An id the catalog does
      // not know keeps the provisional Ultra 2 profile, which is what it is there for.
      let (resolved, productId) = devices.config(forAddress: address)
      config = resolved
      Self.log.notice(
        """
        bose config resolved: \
        productId=\(productId.map { String(format: "0x%04X", $0) } ?? "unknown", privacy: .public) \
        supported=\(productId.map(BoseCatalog.isSupported(productId:)) ?? false, privacy: .public)
        """
      )
      let opened = try await devices.open(address: address, timeout: openTimeout)
      let session = await BoseSession.start(opened: opened, config: config)
      try await session.connect()
      self.session = session

      firmwareVersion = config.supports(.firmwareVersion) ? try? await readFirmware(session) : nil
      snapshot = await readSnapshot(session, includingStable: true)
      // An opened channel that answers nothing is not a connection. Publishing `.ready`
      // here would show an empty panel over a link the next refresh has to tear down
      // anyway, so it fails now — exactly as a refused open does.
      guard snapshot.isControllable else {
        Self.log.notice("bose connected but read nothing back; treating as unreachable")
        await abandonConnect(to: address)
        return
      }
      // One config drives both the wire and the panel. The display axes it carries — wind
      // reduction above all, which the earbuds lack though their [31.10] payload still
      // has the byte — now come from the catalog entry for the announced product id,
      // rather than from looking for "earbud" in a name that is localisable and, on a
      // renamed device, not the model's at all.
      panelModel = BosePanelModel(snapshot: snapshot, config: config, session: session)
      publishReadout(status: .ready)
      Self.log.notice("bose connected: controllable")
    } catch {
      Self.log.notice("bose connect failed: \(String(describing: error), privacy: .public)")
      await abandonConnect(to: address)
    }
  }

  /// The one way out of a connect that did not end controllable, whichever step failed.
  ///
  /// The address is set aside so the next tick tries a different BMAP candidate instead
  /// of the one that just failed, over and over. An open that read nothing back used to
  /// skip this — only a refused open joined the rotation — so a product publishing two
  /// addresses could hold the loop on the silent one for good, reopening it every tick
  /// over the one control channel the device has.
  private func abandonConnect(to address: String) async {
    failedAddresses.insert(Self.normalized(address))
    await teardown(keepingAddress: true)
    readout = Readout(status: .unreachable, modelName: nil, firmwareVersion: nil, battery: .unknown)
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

  /// Closes the session and drops everything read from it — the readout included.
  ///
  /// The readout is what `AppModel.refresh` folds in as the panel's device whenever Sony
  /// has none, so it must not outlive the session it describes. Left in place, the last
  /// `.ready` (name, battery) kept a device on screen after it had left the audio output,
  /// and with no panel model behind it the settings window drew Sony's controls under
  /// Bose ownership. A caller that has something to say about the address it keeps —
  /// that it is unreachable — publishes that afterwards.
  private func teardown(keepingAddress: Bool = false) async {
    if let session {
      await session.close()
    }
    session = nil
    panelModel = nil
    readout = nil
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

    // Every GET is gated on the config, so a model is never asked for a block it would
    // refuse — the whole point of the config carrying its capabilities. The single
    // addresses go by its feature set; the block-31 mode reads go by its declared mode
    // slots instead (`supportsModeBlock`, and `modeSlots`, empty without block 31), not by
    // `.modeConfig` in the feature set.
    if includingStable {
      if config.supports(.deviceName) {
        snap.modelName = try? await readModelName(session)
        readSomething = readSomething || snap.modelName != nil
      }
      if config.supports(.equalizer) {
        snap.equalizerBands = try? await readEqualizer(session)
        readSomething = readSomething || snap.equalizerBands != nil
      }
      modeList = (try? await readModeList(session)) ?? []
      readSomething = readSomething || !modeList.isEmpty
    } else {
      snap.modelName = snapshot.modelName
      snap.equalizerBands = snapshot.equalizerBands
    }

    // Battery [2.2]. A device that is busy can answer with no components at all, so an
    // empty list is still an answer: the read succeeded, which is what the flag tracks.
    if config.supports(.battery), let battery = try? await readBatteryComponents(session) {
      snap.battery = battery
      readSomething = true
    }
    // Noise cancellation level [1.5] — the CNC range and current ambient/ANC balance.
    if config.supports(.noiseCancellationRead) {
      snap.noiseCancellation = try? await readNoiseCancellation(session)
      readSomething = readSomething || snap.noiseCancellation != nil
    }

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

  /// Maps the parsed [2.2] components onto the shared layout.
  ///
  /// A single component is the whole headset. Several become numbered cells, never L / R /
  /// case: `BmapBatteryComponent.componentId` is device-defined, so which enclosure each
  /// reading belongs to is not something the payload declares — the parse layer says so
  /// and deliberately keeps the id raw. Reading the order as left, right, case put the two
  /// earbud charges the wrong way round on any model that reports them differently. The
  /// Bose panel already numbers them (`BosePanelState.batteryReading`); this matches it, so
  /// the notch and the panel agree.
  nonisolated static func batteryLayout(from components: [BmapBatteryComponent]) -> BatteryLayout {
    switch components.count {
    case 0:
      return .unknown
    case 1:
      return .single(components[0].percent)
    default:
      return .numbered(
        components.enumerated().map { index, component in
          BatteryLayout.Cell(slot: index + 1, percent: component.percent)
        }
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
