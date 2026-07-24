import BoseCore
import DeviceContract
import Foundation

/// The pure, value-typed description of what the Bose panel draws. Every feature is
/// optional so a model that does not declare one simply omits it — the page for it says
/// "not declared" rather than showing a dead control.
///
/// This is deliberately Bose-shaped, not a shared feature vocabulary: continuous CNC,
/// independent ANC and wind, a three-band EQ, audio modes, spatial audio, and sidetone
/// are the shapes the Ultra 2 actually has (see `docs/bose-frozen-spec.md`). Sony has its
/// own state and its own pages; the two never share this type (`docs/bose-device-contract.md`).
public struct BosePanelState: Equatable, Sendable {
  /// The product model name only (never the Bluetooth friendly name — that would carry a
  /// personal label). Drawn in the header beside the battery.
  public var modelName: String?
  /// The charge, in the brand-neutral shape the shared closed bar also uses.
  public var battery: BatteryReading

  /// The continuous noise/ambient blend read from the device. Nil when the model does not
  /// declare it.
  public var cnc: BoseCNCState?
  /// Active noise cancellation on/off. Independent of `cnc`: the frozen spec keeps ANC a
  /// separate field in [31.10], and the audible CNC change only appears with ANC on and
  /// wind off (wind block masks the CNC DSP).
  public var ancEnabled: Bool?
  /// Wind-noise reduction on/off, independent of ANC.
  public var windReduction: Bool?

  /// The three-band equalizer (Bass / Mid / Treble). Nil when not declared.
  public var equalizer: BoseEqualizerState?

  /// The audio modes the device carries, with which one is selected.
  public var audioModes: BoseAudioModes?

  /// Spatial audio: off / room-fixed / head-tracked. Rides [31.10] with the noise control.
  public var spatial: BmapNoiseControlSetting.Spatial?

  /// Call-time sidetone: off / high / medium / low.
  public var sidetone: BoseSidetone?

  /// Whether the device is controllable at all — drives the shared closed bar.
  public var isControllable: Bool
  /// Whether the session will accept writes; when false the pages show every reading but
  /// their controls are disabled (a write the session would refuse is never offered).
  public var acceptsWrites: Bool

  public init(
    modelName: String? = nil,
    battery: BatteryReading = .unknown,
    cnc: BoseCNCState? = nil,
    ancEnabled: Bool? = nil,
    windReduction: Bool? = nil,
    equalizer: BoseEqualizerState? = nil,
    audioModes: BoseAudioModes? = nil,
    spatial: BmapNoiseControlSetting.Spatial? = nil,
    sidetone: BoseSidetone? = nil,
    isControllable: Bool = false,
    acceptsWrites: Bool = false
  ) {
    self.modelName = modelName
    self.battery = battery
    self.cnc = cnc
    self.ancEnabled = ancEnabled
    self.windReduction = windReduction
    self.equalizer = equalizer
    self.audioModes = audioModes
    self.spatial = spatial
    self.sidetone = sidetone
    self.isControllable = isControllable
    self.acceptsWrites = acceptsWrites
  }
}

// MARK: - CNC

/// The continuous noise/ambient control.
///
/// The wire is *inverted* from intuition: byte 0 is maximum cancellation (quietest) and
/// the top of the range is maximum ambient (frozen spec §1/§3). Storing the raw wire value
/// keeps the state honest about what the device holds; the UI-facing quantity is
/// `strength` — how much the outside world is cancelled — which counts the other way, so a
/// slider labelled Aware ⇄ Quiet reads naturally without the numbers ever lying. The two
/// static transforms are the single place the inversion lives, so it is tested once and
/// used everywhere.
public struct BoseCNCState: Equatable, Sendable {
  /// The wire domain, always lower-bounded at 0. Upper bound is the device's declared
  /// maximum (`numSteps - 1` from [1.5]).
  public let range: ClosedRange<Int>
  /// The value the device holds, in wire terms: `range.lowerBound` is maximum
  /// cancellation, `range.upperBound` is maximum ambient.
  public let wireValue: Int

  public init(range: ClosedRange<Int>, wireValue: Int) {
    self.range = range
    self.wireValue = Self.clamp(wireValue, to: range)
  }

  public var maximum: Int { range.upperBound }

  /// The cancellation strength the UI presents: `range.upperBound` at maximum
  /// cancellation, 0 at full ambient. This is the inverted view of `wireValue`.
  public var strength: Int { Self.strength(forWire: wireValue, in: range) }

  /// Wire value for a given UI strength — the inverse of `strength`. Used when a drag on
  /// the strength slider is turned back into the byte the device is written.
  public static func wireValue(forStrength strength: Int, in range: ClosedRange<Int>) -> Int {
    // strength counts up toward cancellation; the wire counts up toward ambient, so the
    // two are mirror images across the range's span.
    range.upperBound - clamp(strength, to: range)
  }

  /// UI strength for a given wire value — the inverse of `wireValue(forStrength:)`.
  public static func strength(forWire wire: Int, in range: ClosedRange<Int>) -> Int {
    range.upperBound - clamp(wire, to: range)
  }

  private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }
}

// MARK: - Equalizer

/// One band of the three-band equalizer, in UI terms: its id, the signed range the device
/// declared, and the current gain.
public struct BoseEqualizerBandState: Equatable, Sendable, Identifiable {
  public let bandId: UInt8
  public let range: ClosedRange<Int>
  public let value: Int
  public var id: UInt8 { bandId }

  public init(bandId: UInt8, range: ClosedRange<Int>, value: Int) {
    self.bandId = bandId
    self.range = range
    self.value = min(max(value, range.lowerBound), range.upperBound)
  }
}

public struct BoseEqualizerState: Equatable, Sendable {
  /// Bands in display order: Bass, Mid, Treble.
  public let bands: [BoseEqualizerBandState]

  public init(bands: [BoseEqualizerBandState]) {
    self.bands = bands
  }
}

// MARK: - Audio modes

/// One audio mode (a slot in block 31). The name comes from the device's own STATUS
/// (UTF-8), never coined here; `isEditable` is the device's editable flag (STATUS[3]).
public struct BoseAudioMode: Equatable, Sendable, Identifiable {
  public let slot: Int
  public let name: String
  public let isEditable: Bool
  public var id: Int { slot }

  public init(slot: Int, name: String, isEditable: Bool) {
    self.slot = slot
    self.name = name
    self.isEditable = isEditable
  }
}

public struct BoseAudioModes: Equatable, Sendable {
  public let modes: [BoseAudioMode]
  public let selectedSlot: Int?

  public init(modes: [BoseAudioMode], selectedSlot: Int?) {
    self.modes = modes
    self.selectedSlot = selectedSlot
  }
}

// MARK: - Sidetone

/// Call-time sidetone level. Four steps, matching the frozen spec's four-step control.
/// The wire mapping is not yet reverse-engineered, so this stays a UI-level enum until
/// stage 6 gives it a BoseCore builder.
public enum BoseSidetone: String, Equatable, Sendable, CaseIterable {
  case off
  case high
  case medium
  case low
}
