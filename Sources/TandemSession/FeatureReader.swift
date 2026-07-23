import Foundation
import TandemCore

/// What could be read from the device.
///
/// Every field is optional because a device declares which functions it has, and a
/// field left empty means the device never offered it. Filling one in with a default
/// would put a number on screen that the headphones never said.
public struct DeviceReadings: Equatable, Sendable {
  public var singleBattery: Int?
  public var leftBattery: Int?
  public var rightBattery: Int?
  public var caseBattery: Int?
  public var codec: TandemAudioCodec?
  public var equalizer: EqualizerReading?
  public var noiseControl: NoiseControlReading?
  public var listeningMode: TandemListeningReading?
  public var speakToChat: SpeakToChatReading?
  public var sidetone: SidetoneReading?

  public init() {}
}

/// Call-time sidetone as this device declares it: one of the general-setting slots,
/// identified by the label the device itself attached to the slot — never by the slot
/// number, which nothing says two models assign alike. A device that declares no
/// general-setting slot, or none labelled sidetone, is never read here.
public struct SidetoneReading: Equatable, Sendable {
  public var slot: TandemGeneralSettingSlot
  public var snapshot: TandemGeneralSettingSnapshot

  public init(slot: TandemGeneralSettingSlot, snapshot: TandemGeneralSettingSnapshot) {
    self.slot = slot
    self.snapshot = snapshot
  }

  public var isControlEnabled: Bool { snapshot.isControlEnabled }

  /// The switch value, present only when the device typed the slot as a boolean. A
  /// list-typed sidetone has no switch to draw, so it reads as absent rather than
  /// being forced into one.
  public var isEnabled: Bool? {
    if case .boolean(let enabled) = snapshot.value { return enabled }
    return nil
  }
}

/// Speak-to-chat as this device describes it. The inquiry and the timeout seconds come
/// from the device; a model that declares neither function is never read here.
public struct SpeakToChatReading: Equatable, Sendable {
  public var inquiry: UInt8
  public var capability: TandemSpeakToChatCapability
  public var isEnabled: Bool
  /// The device's second setting field, preserved verbatim so toggling the first never
  /// overwrites a meaning that has not been verified.
  public var secondarySettingEnabled: Bool
  public var sensitivity: TandemSpeakToChatSensitivity
  public var timeout: TandemSpeakToChatTimeout

  public init(
    inquiry: UInt8,
    capability: TandemSpeakToChatCapability,
    isEnabled: Bool,
    secondarySettingEnabled: Bool,
    sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout
  ) {
    self.inquiry = inquiry
    self.capability = capability
    self.isEnabled = isEnabled
    self.secondarySettingEnabled = secondarySettingEnabled
    self.sensitivity = sensitivity
    self.timeout = timeout
  }
}

/// Noise control as this device describes it.
///
/// The inquiry byte, the number of ambient modes, and the level range all come from
/// the device. None is assumed, so a model nobody has tested still gets the right
/// controls.
public struct NoiseControlReading: Equatable, Sendable {
  public var inquiry: UInt8
  public var modes: [TandemAmbientModeCapability]
  public var state: TandemNoiseControlState
  /// How many bytes the device's parameter response carried after command and inquiry.
  /// Writes are trimmed to this so a simpler dialect is never sent fields it lacks.
  public var valueFieldCount: Int
  /// The older generation's wind byte, echoed back on writes: under it the noise
  /// cancelling submode is 2, not 1, and writing the wrong one turns on wind noise
  /// reduction instead of noise cancelling.
  public var legacyWindKind: UInt8

  public init(
    inquiry: UInt8,
    modes: [TandemAmbientModeCapability],
    state: TandemNoiseControlState,
    valueFieldCount: Int = 0,
    legacyWindKind: UInt8 = 0
  ) {
    self.inquiry = inquiry
    self.modes = modes
    self.state = state
    self.valueFieldCount = valueFieldCount
    self.legacyWindKind = legacyWindKind
  }

  public var hasAdjustableLevel: Bool {
    TandemNoiseControlType.hasAdjustableLevel(inquiry) && !modes.isEmpty
  }

  public var supportsVoiceFocus: Bool { modes.contains { $0.mode == 1 } }
  public var supportsNoiseCancelling: Bool { TandemNoiseControlType.hasNoiseCancelling(inquiry) }
  public var supportsAmbient: Bool { TandemNoiseControlType.hasAmbient(inquiry) }

  public func range(for mode: UInt8) -> ClosedRange<Int> {
    modes.first { $0.mode == mode }?.range ?? 0...0
  }

  public func step(for mode: UInt8) -> Int {
    max(modes.first { $0.mode == mode }?.step ?? 1, 1)
  }

  /// Aligns a level to the mode's declared minimum and step, so the device is never
  /// sent a value it did not advertise.
  public func quantizedLevel(_ level: Int, mode: UInt8) -> Int {
    let range = range(for: mode)
    let step = step(for: mode)
    let clamped = min(max(level, range.lowerBound), range.upperBound)
    let aligned = range.lowerBound + ((clamped - range.lowerBound + step / 2) / step) * step
    return min(max(aligned, range.lowerBound), range.upperBound)
  }
}

/// The equaliser as this device describes it.
///
/// Band count, band frequencies, and the list of presets all come from the device.
/// Models differ in every one of them, so none may be assumed.
public struct EqualizerReading: Equatable, Sendable {
  public struct Preset: Equatable, Sendable, Identifiable {
    public let identifier: UInt8
    /// Only present when the device sent one. Every model tested so far sends none,
    /// whatever display language is asked for, so this is usually empty.
    public let name: String?

    public var id: UInt8 { identifier }
  }

  public var presets: [Preset]
  public var selectedPreset: UInt8?
  /// Centre frequency per band, in hertz, in the order the steps are given.
  public var bandFrequencies: [Int]
  public var bandSteps: [Int]
  public var stepRange: ClosedRange<Int>
  /// The step that means no change. Steps run from zero, so this is the middle one.
  public var flatStep: Int

  public init(
    presets: [Preset],
    selectedPreset: UInt8?,
    bandFrequencies: [Int],
    bandSteps: [Int],
    stepRange: ClosedRange<Int>,
    flatStep: Int
  ) {
    self.presets = presets
    self.selectedPreset = selectedPreset
    self.bandFrequencies = bandFrequencies
    self.bandSteps = bandSteps
    self.stepRange = stepRange
    self.flatStep = flatStep
  }

  public var bandCount: Int { bandFrequencies.count }
  public var levelStepCount: Int { stepRange.upperBound + 1 }

  /// The preset a band edit lands on. Editing bands is a custom-preset action, so it
  /// uses whichever custom slot the device declares — the current one if it is already
  /// custom — and is `nil` for a device that declares no custom preset, which then does
  /// not allow band editing at all.
  public var editablePresetIdentifier: UInt8? {
    let customs = presets.map(\.identifier).filter { $0 >= 0xA0 }
    if let selectedPreset, customs.contains(selectedPreset) { return selectedPreset }
    return customs.first
  }

  public var canEditBands: Bool { editablePresetIdentifier != nil }

  /// Decibels either side of flat, which is what a listener is actually adjusting.
  public func decibels(atBand index: Int) -> Int {
    guard bandSteps.indices.contains(index) else { return 0 }
    return bandSteps[index] - flatStep
  }

  /// A copy with one band moved to a new step, clamped to the declared range. Used to
  /// build the payload for a band edit without mutating the current reading.
  public func settingBand(_ index: Int, toStep step: Int) -> [UInt8] {
    var steps = bandSteps
    guard steps.indices.contains(index) else { return steps.map { UInt8(clamping: $0) } }
    steps[index] = min(max(step, stepRange.lowerBound), stepRange.upperBound)
    return steps.map { UInt8(clamping: $0) }
  }

  public var bandStepsBytes: [UInt8] { bandSteps.map { UInt8(clamping: $0) } }
}

/// Reads the values this application knows how to interpret.
///
/// Which requests are sent follows from the function codes the device declared, not
/// from its model name. Reads have no side effect, so there is no reason to withhold
/// them from a device that has never been verified; only writes carry that risk.
public struct FeatureReader: Sendable {
  public init() {}

  public func read(
    declaring functions: [TandemSupportFunction],
    dialect: TandemDialect = .current,
    over requests: SessionRequesting
  ) async -> DeviceReadings {
    guard dialect == .current else {
      return await readLegacy(declaring: functions, over: requests)
    }
    let declared = Set(functions.map(\.code))
    var readings = DeviceReadings()

    if let query = Self.batteryQuery(declared: declared) {
      await readBattery(query, into: &readings, over: requests)
    }
    await readCaseBattery(declared: declared, into: &readings, over: requests)
    if declared.contains(Self.codecFunction) {
      readings.codec = try? await readCodec(over: requests)
    }
    if declared.contains(Self.equalizerFunction) {
      readings.equalizer = try? await readEqualizer(over: requests)
    }
    if let inquiry = TandemNoiseControlType.inquiry(forDeclared: declared) {
      readings.noiseControl = try? await readNoiseControl(inquiry, over: requests)
    }
    let listeningFeatures = TandemListeningCatalog.features(forDeclared: declared)
    if !listeningFeatures.isEmpty {
      readings.listeningMode = await readListening(listeningFeatures, over: requests)
    }
    if let inquiry = TandemSpeakToChatProtocol.inquiry(forDeclared: declared) {
      readings.speakToChat = try? await readSpeakToChat(inquiry, over: requests)
    }
    let generalSlots = TandemGeneralSettingSlot.allCases.filter { declared.contains($0.rawValue) }
    if !generalSlots.isEmpty {
      readings.sidetone = await readSidetone(declaredSlots: generalSlots, over: requests)
    }
    return readings
  }

  // MARK: - The older generation

  /// The older generation's support table names the get-command bytes the device
  /// answers, listed as bare codes. These are the commands of its documented
  /// conversations — generation constants, not any model's values — used only to
  /// check what a device itself declared.
  private static let legacyBatteryFunction: UInt8 = 0x10
  private static let legacyCodecFunction: UInt8 = 0x18
  private static let legacyNoiseFunction: UInt8 = 0x66
  private static let legacyEqualizerFunction: UInt8 = 0x56

  /// The read set for the older generation, whose support table names commands the
  /// newer catalogue does not map. Each conversation is gated on the device having
  /// declared its command: asking regardless was not harmless, because a request the
  /// device never answers times out and tears down the session, once per poll cycle,
  /// for every function the device does not have.
  private func readLegacy(
    declaring functions: [TandemSupportFunction],
    over requests: SessionRequesting
  ) async -> DeviceReadings {
    let declared = Set(functions.map(\.code))
    var readings = DeviceReadings()

    // Earbuds answer the dual query, headbands the single one; ask in that order and
    // let the shape of the answers say which the device is. A dual answer means a
    // charging case exists to ask about too. The declaration cannot say which shape
    // the device is — both ride the same command — so these are probes: the shape
    // the device is not must go unanswered without costing the session.
    if declared.contains(Self.legacyBatteryFunction) {
      await readBattery(.leftRight, dialect: .legacy, asProbe: true, into: &readings, over: requests)
      if readings.leftBattery == nil, readings.rightBattery == nil {
        await readBattery(.single, dialect: .legacy, asProbe: true, into: &readings, over: requests)
      } else {
        await readBattery(
          .chargingCase, dialect: .legacy, asProbe: true, into: &readings, over: requests
        )
      }
    }

    if declared.contains(Self.legacyCodecFunction) {
      readings.codec = try? await readCodec(dialect: .legacy, over: requests)
    }
    if declared.contains(Self.legacyNoiseFunction) {
      readings.noiseControl = try? await readLegacyNoiseControl(over: requests)
    }
    if declared.contains(Self.legacyEqualizerFunction) {
      readings.equalizer = try? await readLegacyEqualizer(over: requests)
    }
    return readings
  }

  private func readLegacyNoiseControl(
    over requests: SessionRequesting
  ) async throws -> NoiseControlReading {
    let inquiry = TandemNoiseControlProtocol.legacyInquiry
    let frame = try await requests.request(
      { try TandemNoiseControlProtocol.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0x67, inquiry: inquiry)
    )
    let state = try TandemNoiseControlProtocol.parseParameterResponse(frame, inquiry: inquiry)
    let bytes = [UInt8](frame.payload)
    return NoiseControlReading(
      inquiry: inquiry,
      // The generation does not announce its modes; they are fixed by its dialect.
      modes: TandemNoiseControlProtocol.legacyAmbientModes,
      state: state,
      valueFieldCount: max(frame.payload.count - 2, 0),
      legacyWindKind: bytes.count > 3 ? bytes[3] : 0
    )
  }

  /// The presets and bands the older generation has but does not announce: a clear
  /// bass control and five fixed bands, cut or boosted ten steps either way, with the
  /// documented preset set. Fixed by the generation, not by any model.
  private static let legacyEqualizerPresets: [UInt8] = [
    0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2,
  ]
  private static let legacyEqualizerFrequencies: [Int] = [0, 400, 1000, 2500, 6300, 16000]

  private func readLegacyEqualizer(
    over requests: SessionRequesting
  ) async throws -> EqualizerReading {
    let inquiry = TandemReadOnlyEqualizer.legacyInquiry
    let capability = TandemEqualizerCapability(
      bandCount: Self.legacyEqualizerFrequencies.count,
      levelStepCount: 21,
      presets: Self.legacyEqualizerPresets.map {
        TandemEqualizerPreset(identifier: $0, name: "")
      }
    )
    let frame = try await requests.request(
      { try TandemReadOnlyEqualizer.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0x57, inquiry: inquiry)
    )
    let parameters = try TandemReadOnlyEqualizer.parseParameterResponse(
      frame,
      capability: capability,
      inquiry: inquiry
    )
    return EqualizerReading(
      presets: capability.presets.map {
        EqualizerReading.Preset(
          identifier: $0.identifier,
          name: TandemEqualizerPresetNames.name(for: $0.identifier)
        )
      },
      selectedPreset: parameters.presetIdentifier,
      bandFrequencies: Self.legacyEqualizerFrequencies,
      bandSteps: parameters.bandSteps.map(Int.init),
      stepRange: 0...max(capability.levelStepCount - 1, 0),
      flatStep: capability.flatStep
    )
  }

  // MARK: - Speak-to-chat

  private func readSpeakToChat(
    _ inquiry: UInt8,
    over requests: SessionRequesting
  ) async throws -> SpeakToChatReading {
    let capabilityFrame = try await requests.request(
      { try TandemSpeakToChatProtocol.capabilityRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0xF1, inquiry: inquiry)
    )
    let capability = try TandemSpeakToChatProtocol.parseCapabilityResponse(
      capabilityFrame,
      inquiry: inquiry
    )

    let parameterFrame = try await requests.request(
      { try TandemSpeakToChatProtocol.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0xF7, inquiry: inquiry)
    )
    let parameters = try TandemSpeakToChatProtocol.parseParameterResponse(
      parameterFrame,
      inquiry: inquiry
    )

    let detailFrame = try await requests.request(
      { try TandemSpeakToChatProtocol.extendedParameterRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0xFB, inquiry: inquiry)
    )
    let detail = try TandemSpeakToChatProtocol.parseExtendedParameterResponse(
      detailFrame,
      inquiry: inquiry
    )

    return SpeakToChatReading(
      inquiry: inquiry,
      capability: capability,
      isEnabled: parameters.isEnabled,
      secondarySettingEnabled: parameters.secondarySettingEnabled,
      sensitivity: detail.sensitivity,
      timeout: detail.timeout
    )
  }

  // MARK: - Sidetone (general settings)

  /// Finds the declared general-setting slot whose own label names sidetone, and reads
  /// its status and value. The other slots' capabilities are read and discarded: which
  /// slot means what is the device's to say, so every declared one has to be asked.
  ///
  /// The capability inquiry is a probe, not a request: a slot's capability is an
  /// optional facet of the declaration, and a model that declares the slot but leaves
  /// the label query unanswered must not tear down a working session over it. A slot
  /// that did answer its capability demonstrably serves this conversation, so its
  /// status and parameter reads follow the declared-feature rule and use plain
  /// requests.
  private func readSidetone(
    declaredSlots: [TandemGeneralSettingSlot],
    over requests: SessionRequesting
  ) async -> SidetoneReading? {
    for slot in declaredSlots {
      guard
        let capabilityFrame = try? await requests.probe(
          { try TandemGeneralSettingProtocol.capabilityRequest(sequence: $0, slot: slot) },
          matching: Self.answers(0xD1, inquiry: slot.rawValue)
        ),
        let capability = try? TandemGeneralSettingProtocol.parseCapabilityResponse(capabilityFrame),
        capability.isSidetone
      else { continue }

      guard
        let statusFrame = try? await requests.request(
          { try TandemGeneralSettingProtocol.statusRequest(sequence: $0, slot: slot) },
          matching: Self.answers(0xD3, inquiry: slot.rawValue)
        ),
        let isControlEnabled = try? TandemGeneralSettingProtocol.parseStatusResponse(
          statusFrame, slot: slot
        ),
        let parameterFrame = try? await requests.request(
          { try TandemGeneralSettingProtocol.parameterRequest(sequence: $0, slot: slot) },
          matching: Self.answers(0xD7, inquiry: slot.rawValue)
        ),
        let value = try? TandemGeneralSettingProtocol.parseParameterResponse(
          parameterFrame, capability: capability
        )
      else { return nil }

      return SidetoneReading(
        slot: slot,
        snapshot: TandemGeneralSettingSnapshot(
          capability: capability,
          isControlEnabled: isControlEnabled,
          value: value
        )
      )
    }
    return nil
  }

  // MARK: - Listening mode

  /// Reads only the listening features the device declared. A model that declares
  /// none never reaches here, so no listening message is sent to a device without
  /// the feature.
  private func readListening(
    _ features: [TandemListeningFeature],
    over requests: SessionRequesting
  ) async -> TandemListeningReading? {
    var states: [UInt8: TandemListeningFeatureState] = [:]
    for feature in features {
      guard
        let frame = try? await requests.request(
          { try TandemListeningModeProtocol.parameterRequest(sequence: $0, inquiry: feature.inquiry) },
          matching: Self.answers(0xE7, inquiry: feature.inquiry)
        ),
        let state = try? TandemListeningModeProtocol.parseParameterResponse(frame, feature: feature)
      else { continue }
      states[feature.inquiry] = state
    }
    guard !states.isEmpty else { return nil }
    return TandemListeningReading.resolve(features: features, states: states)
  }

  // MARK: - Noise control

  private func readNoiseControl(
    _ inquiry: UInt8,
    over requests: SessionRequesting
  ) async throws -> NoiseControlReading {
    let capabilityFrame = try await requests.request(
      { try TandemNoiseControlProtocol.capabilityRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0x61, inquiry: inquiry)
    )
    let modes = try TandemNoiseControlProtocol.parseCapabilityResponse(
      capabilityFrame,
      inquiry: inquiry
    )

    let parameterFrame = try await requests.request(
      { try TandemNoiseControlProtocol.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: Self.answers(0x67, inquiry: inquiry)
    )
    let state = try TandemNoiseControlProtocol.parseParameterResponse(
      parameterFrame,
      inquiry: inquiry
    )

    // The value bytes are everything past the command and inquiry; writes are trimmed
    // to this so the device is only ever sent the fields it itself reports.
    let valueFieldCount = max(parameterFrame.payload.count - 2, 0)
    return NoiseControlReading(
      inquiry: inquiry,
      modes: modes,
      state: state,
      valueFieldCount: valueFieldCount
    )
  }

  // MARK: - Equaliser

  private static let equalizerFunction: UInt8 = 0x57

  private func readEqualizer(over requests: SessionRequesting) async throws -> EqualizerReading {
    let capabilityFrame = try await requests.request(
      { try TandemReadOnlyEqualizer.capabilityRequest(sequence: $0) },
      matching: Self.answers(0x51, inquiry: TandemReadOnlyEqualizer.presetEqualizerWithErrorCodeInquiry)
    )
    let capability = try TandemReadOnlyEqualizer.parseCapabilityResponse(capabilityFrame)

    let parameterFrame = try await requests.request(
      { try TandemReadOnlyEqualizer.parameterRequest(sequence: $0) },
      matching: Self.answers(0x57, inquiry: TandemReadOnlyEqualizer.presetEqualizerWithErrorCodeInquiry)
    )
    let parameters = try TandemReadOnlyEqualizer.parseParameterResponse(
      parameterFrame,
      capability: capability
    )

    // Band frequencies live in the extended information, not in the capability.
    // Without them the sliders are unlabelled — which is exactly the designed
    // fallback below. A probe, not a request: a model that declares the equaliser
    // but never answers the extended query must land on that fallback, not have the
    // request's timeout tear down the whole connection on the way there.
    let frequencies: [Int]
    if let extendedFrame = try? await requests.probe(
      { try TandemReadOnlyEqualizer.extendedInfoRequest(sequence: $0) },
      matching: Self.answers(0x5B, inquiry: TandemReadOnlyEqualizer.presetEqualizerWithErrorCodeInquiry)
    ),
      let bands = try? TandemReadOnlyEqualizer.parseExtendedInfoResponse(
        extendedFrame,
        capability: capability
      )
    {
      frequencies = bands.map { Int($0.value) }
    } else {
      frequencies = Array(repeating: 0, count: capability.bandCount)
    }

    return EqualizerReading(
      presets: capability.presets.map {
        EqualizerReading.Preset(
          identifier: $0.identifier,
          // The device sends no name, so fall back to the documented table.
          name: $0.name.isEmpty
            ? TandemEqualizerPresetNames.name(for: $0.identifier)
            : $0.name
        )
      },
      selectedPreset: parameters.presetIdentifier,
      bandFrequencies: frequencies,
      bandSteps: parameters.bandSteps.map(Int.init),
      stepRange: 0...max(capability.levelStepCount - 1, 0),
      flatStep: capability.flatStep
    )
  }

  // MARK: - Battery

  private static let codecFunction: UInt8 = 0x12

  /// The threshold-carrying variants are what newer models use for the same value.
  private static func batteryQuery(declared: Set<UInt8>) -> TandemBatteryQuery? {
    if declared.contains(0x29) { return .leftRightWithThreshold }
    if declared.contains(0x21) { return .leftRight }
    if declared.contains(0x28) { return .singleWithThreshold }
    if declared.contains(0x20) { return .single }
    return nil
  }

  /// `asProbe` sends the query on the probe path, whose timeout fails only itself.
  /// Used where silence is part of the conversation — the legacy battery shape
  /// detection — and never for a query the declaration promises an answer to.
  private func readBattery(
    _ query: TandemBatteryQuery,
    dialect: TandemDialect = .current,
    asProbe: Bool = false,
    into readings: inout DeviceReadings,
    over requests: SessionRequesting
  ) async {
    let returnCommand =
      dialect == .legacy ? TandemReadOnlyStatus.legacyBatteryReturn : Self.powerReturnStatus
    let build: @Sendable (UInt8) throws -> TandemFrame = {
      try TandemReadOnlyStatus.batteryRequest(query: query, sequence: $0, dialect: dialect)
    }
    let matching = Self.answers(returnCommand, inquiry: query.rawValue)
    guard
      let frame = asProbe
        ? try? await requests.probe(build, matching: matching)
        : try? await requests.request(build, matching: matching),
      let status = try? TandemReadOnlyStatus.parseBatteryResponse(
        frame, query: query, dialect: dialect
      )
    else {
      return
    }

    switch query {
    case .single, .singleWithThreshold:
      readings.singleBattery = status.units.first.map { Int($0.percent) }
    case .leftRight, .leftRightWithThreshold:
      readings.leftBattery = status.units.first.map { Int($0.percent) }
      readings.rightBattery = status.units.dropFirst().first.map { Int($0.percent) }
    case .chargingCase, .chargingCaseWithThreshold:
      readings.caseBattery = status.units.first.map { Int($0.percent) }
    }
  }

  /// Charging-case charge is a separate request from the earbud charge.
  private func readCaseBattery(
    declared: Set<UInt8>,
    into readings: inout DeviceReadings,
    over requests: SessionRequesting
  ) async {
    let query: TandemBatteryQuery
    if declared.contains(0x2A) {
      query = .chargingCaseWithThreshold
    } else if declared.contains(0x22) {
      query = .chargingCase
    } else {
      return
    }
    await readBattery(query, into: &readings, over: requests)
  }

  // MARK: - Codec

  private func readCodec(
    dialect: TandemDialect = .current,
    over requests: SessionRequesting
  ) async throws -> TandemAudioCodec {
    let returnCommand =
      dialect == .legacy ? TandemReadOnlyStatus.legacyCodecReturn : Self.commonReturnStatus
    let inquiry: UInt8 = dialect == .legacy ? 0x00 : Self.audioCodecInquiry
    let frame = try await requests.request(
      { try TandemReadOnlyStatus.audioCodecRequest(sequence: $0, dialect: dialect) },
      matching: Self.answers(returnCommand, inquiry: inquiry)
    )
    return try TandemReadOnlyStatus.parseAudioCodecResponse(frame, dialect: dialect)
  }

  private static let commonReturnStatus: UInt8 = 0x13
  private static let powerReturnStatus: UInt8 = 0x23
  private static let audioCodecInquiry: UInt8 = 0x02

  /// Matches on the inquiry as well as the command, so a battery answer cannot be
  /// mistaken for a codec answer when both are outstanding.
  private static func answers(
    _ command: UInt8,
    inquiry: UInt8
  ) -> @Sendable (TandemFrame) -> Bool {
    { frame in
      let bytes = [UInt8](frame.payload)
      return frame.dataType == TandemFrame.table1DataType
        && bytes.count >= 2
        && bytes[0] == command
        && bytes[1] == inquiry
    }
  }
}
