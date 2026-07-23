import Testing

@testable import DeviceContract

/// The point of freezing the contract before implementation: prove each real device's
/// shape can be *held* by these types without loss or forcing. These fixtures build a
/// representative Sony, Bose Ultra, and Bose QC35 device state from the frozen spec and
/// assert the shape survives — if a device cannot be expressed, the contract is wrong,
/// and it fails here rather than deep in an adapter later.
struct ProjectionFixtureTests {
  // MARK: - Sony (e.g. WH-1000XM6): discrete NC with ambient level, presets + bands,
  // listening modes with a BGM room parameter, speak-to-chat, sidetone.
  @Test("Sony's full feature shape fits the contract")
  func sonyProjection() {
    let noise = NoiseControlSnapshot(
      topology: .discrete(
        options: [
          NoiseOption(id: OptionID("noiseCancelling")),
          NoiseOption(id: OptionID("ambient"), level: LevelRange(min: 0, max: 20, current: 12)),
          NoiseOption(id: OptionID("off")),
        ],
        selected: OptionID("ambient")
      ),
      voiceFocus: true,          // Sony's own axis
      adaptive: false
    )
    // The selected ambient mode carries its own level — a discrete mode with a range.
    guard case .discrete(let options, let selected) = noise.topology else {
      Issue.record("expected discrete topology"); return
    }
    #expect(selected == OptionID("ambient"))
    #expect(options.first { $0.id == selected }?.level?.current == 12)
    #expect(noise.voiceFocus == true)
    #expect(noise.windReduction == nil)          // Sony has no wind axis

    let eq = EqualizerSnapshot(
      presets: [
        .init(id: OptionID("off")),
        .init(id: OptionID("custom"), isEditable: true),
      ],
      selectedPreset: OptionID("custom"),
      bands: [
        .init(id: OptionID("b0"), range: LevelRange(min: -10, max: 10, current: 3), frequencyHz: 400),
        .init(id: OptionID("b1"), range: LevelRange(min: -10, max: 10, current: 0), frequencyHz: 1000),
      ]
    )
    // Band editing available because the selected preset is editable.
    #expect(eq.presets.first { $0.id == eq.selectedPreset }?.isEditable == true)
    #expect(eq.bands?.first?.frequencyHz == 400)

    // Listening modes with BGM holding a room parameter.
    let modes = AudioModeSnapshot(
      modes: [
        .init(id: OptionID("standard")),
        .init(
          id: OptionID("bgm"),
          parameter: .init(options: [OptionID("myRoom"), OptionID("living")], selected: OptionID("living"))
        ),
        .init(id: OptionID("cinema")),
      ],
      selected: OptionID("bgm")
    )
    #expect(modes.modes.first { $0.id == OptionID("bgm") }?.parameter?.selected == OptionID("living"))

    let state = DeviceState(
      revision: 7,
      descriptor: DeviceDescriptor(brand: .sony, modelName: "WH-1000XM6", firmwareVersion: "1.0.0"),
      phase: .ready,
      capabilities: DeviceCapabilities(
        trust: .verified,
        writeAvailability: .writable,
        features: [
          .noiseControl: .init(read: .fresh, write: .writable),
          .equalizer: .init(read: .fresh, write: .writable),
          .audioMode: .init(read: .fresh, write: .writable),
          .speakToChat: .init(read: .fresh, write: .writable),
          .sidetone: .init(read: .fresh, write: .writable),
        ]
      ),
      battery: BatteryReading(cells: [.init(enclosure: .single, percent: 72, charge: .notCharging)]),
      noiseControl: noise,
      equalizer: eq,
      audioMode: modes,
      sidetone: .toggle(isOn: false),
      speakToChat: .speakToChat(SpeakToChatSnapshot(
        isOn: true,
        sensitivity: [OptionID("auto"), OptionID("high")],
        selectedSensitivity: OptionID("auto"),
        timeout: [OptionID("15s"), OptionID("untilReleased")],   // "until released" is a plain option
        selectedTimeout: OptionID("untilReleased")
      ))
    )
    #expect(state.capabilities.canWrite(.equalizer))
    #expect(state.multipoint == nil)             // not declared on this fixture
  }

  // MARK: - Bose QC Ultra 2: continuous CNC axis, independent ANC/wind, 3-band EQ
  // (no frequency), editable audio modes, spatial as a 3-value choice.
  @Test("Bose Ultra's continuous CNC and independent axes fit the contract")
  func boseUltraProjection() {
    // CNC 0-10 is one axis from full noise-cancelling to full ambient — a midpoint is
    // neither mode, so it must be continuous, not a discrete mode set.
    let noise = NoiseControlSnapshot(
      topology: .continuous(
        LevelRange(min: 0, max: 10, current: 5),
        endpoints: AxisEndpoints(low: .noiseCancelling, high: .ambient)
      ),
      windReduction: false,             // Bose's own axis, own polarity
      noiseCancellingEnabled: true      // independent ANC toggle, sent atomically by the adapter
    )
    guard case .continuous(let range, let ends) = noise.topology else {
      Issue.record("expected continuous topology"); return
    }
    #expect(range.max == 10)
    #expect(ends.low == .noiseCancelling && ends.high == .ambient)
    #expect(noise.noiseCancellingEnabled == true)
    #expect(noise.voiceFocus == nil)             // Bose has no Sony voice-focus

    // 3-band EQ with no frequency — the id labels the band (Bass/Mid/Treble).
    let eq = EqualizerSnapshot(
      presets: [],                                // Ultra exposes bands, not presets
      bands: [
        .init(id: OptionID("bass"), range: LevelRange(min: -10, max: 10, current: 0)),
        .init(id: OptionID("mid"), range: LevelRange(min: -10, max: 10, current: -2)),
        .init(id: OptionID("treble"), range: LevelRange(min: -10, max: 10, current: -6)),
      ]
    )
    #expect(eq.presets.isEmpty)
    #expect(eq.bands?.count == 3)
    #expect(eq.bands?.first?.frequencyHz == nil) // no frequency declared; id is the label

    // Audio modes with per-slot editability (presets locked, custom slots editable).
    let modes = AudioModeSnapshot(
      modes: [
        .init(id: OptionID("quiet"), isEditable: false),
        .init(id: OptionID("aware"), isEditable: false),
        .init(id: OptionID("home"), isEditable: true),      // configured custom slot
        .init(id: OptionID("slot5"), isEditable: true),
      ],
      selected: OptionID("quiet")
    )
    #expect(modes.modes.filter(\.isEditable).count == 2)

    let state = DeviceState(
      descriptor: DeviceDescriptor(brand: .bose, modelName: "QC Ultra 2", firmwareVersion: "8.2.20"),
      phase: .unverified(.unverifiedFirmware),
      capabilities: DeviceCapabilities(
        trust: .unverified(.unverifiedFirmware),
        writeAvailability: .writable,             // experimental firmware still writable
        features: [
          .noiseControl: .init(read: .fresh, write: .writable),
          .equalizer: .init(read: .fresh, write: .writable),
          .audioMode: .init(read: .fresh, write: .writable),
          .spatialAudio: .init(read: .fresh, write: .writable),
          .sidetone: .init(read: .fresh, write: .writable),
          .multipoint: .init(read: .fresh, write: .writable),
        ]
      ),
      battery: BatteryReading(cells: [.init(enclosure: .single, percent: 80)]),
      noiseControl: noise,
      equalizer: eq,
      audioMode: modes,
      // Spatial is three values, not a bool.
      spatialAudio: .choice(options: [OptionID("off"), OptionID("room"), OptionID("head")], selected: OptionID("off")),
      // Sidetone is four values on Bose.
      sidetone: .choice(
        options: [OptionID("off"), OptionID("high"), OptionID("medium"), OptionID("low")],
        selected: OptionID("medium")
      ),
      multipoint: MultipointSnapshot(isEnabled: true, slots: [.init(id: 0, isActive: true), .init(id: 1, isActive: false)])
    )
    #expect(state.phase.isReadable)
    #expect(state.capabilities.trust == .unverified(.unverifiedFirmware))
    // Multipoint slots are indices, carrying no address.
    #expect(state.multipoint?.slots.first?.id == 0)
  }

  // MARK: - Bose QC35: discrete off/high/low (no level), no EQ, no audio modes.
  @Test("Bose QC35's discrete no-level ANR fits the contract")
  func boseQC35Projection() {
    // off/high/low are discrete with NO level — high and low are ANC strengths, not
    // ambient. This is the shape the first draft could not express.
    let noise = NoiseControlSnapshot(
      topology: .discrete(
        options: [
          NoiseOption(id: OptionID("off")),
          NoiseOption(id: OptionID("high")),   // no level range
          NoiseOption(id: OptionID("low")),
        ],
        selected: OptionID("high")
      )
    )
    guard case .discrete(let options, _) = noise.topology else {
      Issue.record("expected discrete topology"); return
    }
    #expect(options.allSatisfy { $0.level == nil })   // no level on any option
    #expect(noise.noiseCancellingEnabled == nil)      // no independent ANC axis on QC35

    let state = DeviceState(
      descriptor: DeviceDescriptor(brand: .bose, modelName: "QC35 II", firmwareVersion: "4.8.1"),
      phase: .ready,
      capabilities: DeviceCapabilities(
        trust: .verified,
        writeAvailability: .writable,
        features: [
          .noiseControl: .init(read: .fresh, write: .writable),
          .sidetone: .init(read: .fresh, write: .writable),
        ]
      ),
      battery: BatteryReading(cells: [.init(enclosure: .single, percent: 64)]),
      noiseControl: noise,
      sidetone: .choice(
        options: [OptionID("off"), OptionID("high"), OptionID("medium"), OptionID("low")],
        selected: OptionID("off")
      )
    )
    #expect(state.equalizer == nil)              // QC35 has no EQ — simply absent
    #expect(state.audioMode == nil)              // no audio modes
    #expect(!state.capabilities.declares(.equalizer))
  }

  // MARK: - Commands reference opaque ids and carry a revision.
  @Test("Commands carry opaque ids and the revision they were built from")
  func commandShape() {
    let cmd = RevisionedCommand(
      basedOnRevision: 7,
      command: .setEqualizerBand(OptionID("bass"), 3, isFinal: true)
    )
    #expect(cmd.basedOnRevision == 7)
    // A stale command names an old revision; the session compares and can reject it.
    let stale = RevisionedCommand(basedOnRevision: 1, command: .selectNoiseOption(OptionID("off")))
    #expect(stale.basedOnRevision != cmd.basedOnRevision)
  }
}
