/// The per-feature snapshots the panel draws. Values that identify an option always use
/// an opaque, stable `raw` id — never an array index (fragile to reordering and stale
/// snapshots) and never a user-editable name (a Bose custom mode name is not an id).
/// Display names are the UI's job, resolved from the id, so no localised text lives here.

/// A stable, opaque identifier for one selectable option. `raw` is a wire-stable token
/// (a preset code, a band key, a mode slot), not a display label.
public struct OptionID: Sendable, Equatable, Hashable {
  public let raw: String
  public init(_ raw: String) { self.raw = raw }
}

/// A continuous axis: min…max with the current value and the step it moves in.
public struct LevelRange: Sendable, Equatable {
  public var min: Int
  public var max: Int
  public var current: Int
  public var step: Int

  public init(min: Int, max: Int, current: Int, step: Int = 1) {
    self.min = min
    self.max = max
    self.current = current
    self.step = step
  }
}

// MARK: - Noise control

/// The primary noise control differs in shape by device, so it is modelled by topology
/// rather than one fixed mode set:
/// - Sony exposes discrete modes (NC / ambient / off), each carrying its own ambient
///   level range.
/// - Bose Ultra exposes one continuous axis from full noise-cancelling to full ambient
///   (a midpoint is neither "NC" nor "ambient" — it cannot be a single mode).
/// - Bose QC35 exposes discrete steps (off / high / low) with no level.
public enum NoiseTopology: Sendable, Equatable {
  case discrete(options: [NoiseOption], selected: OptionID?)
  case continuous(LevelRange, endpoints: AxisEndpoints)
}

public struct NoiseOption: Sendable, Equatable, Identifiable {
  public var id: OptionID
  /// The ambient level within this mode, when the mode carries one (Sony ambient).
  public var level: LevelRange?

  public init(id: OptionID, level: LevelRange? = nil) {
    self.id = id
    self.level = level
  }
}

/// What each end of a continuous axis means, so the UI can label a bare slider.
public struct AxisEndpoints: Sendable, Equatable {
  public var low: NoiseAnchor
  public var high: NoiseAnchor
  public init(low: NoiseAnchor, high: NoiseAnchor) {
    self.low = low
    self.high = high
  }
}

public enum NoiseAnchor: Sendable, Equatable {
  case noiseCancelling
  case ambient
  case off
}

/// The primary topology plus the independent switches that ride alongside it — each
/// present only if the device declares it. Bose Ultra sends CNC + ANC + wind atomically
/// as five bytes; the adapter recombines these fields into that one write. They are kept
/// separate here because they are genuinely independent axes with their own meaning and
/// polarity (Sony voice-focus is not Bose wind-off).
public struct NoiseControlSnapshot: Sendable, Equatable {
  public var topology: NoiseTopology
  /// Sony: focus on voice. Its own meaning; not shared with wind.
  public var voiceFocus: Bool?
  /// Bose: wind block. Its own meaning and polarity.
  public var windReduction: Bool?
  /// Bose Ultra: independent ANC enable, separate from the CNC level.
  public var noiseCancellingEnabled: Bool?
  /// Sony: noise adaptation.
  public var adaptive: Bool?

  public init(
    topology: NoiseTopology,
    voiceFocus: Bool? = nil,
    windReduction: Bool? = nil,
    noiseCancellingEnabled: Bool? = nil,
    adaptive: Bool? = nil
  ) {
    self.topology = topology
    self.voiceFocus = voiceFocus
    self.windReduction = windReduction
    self.noiseCancellingEnabled = noiseCancellingEnabled
    self.adaptive = adaptive
  }
}

// MARK: - Equalizer

public struct EqualizerSnapshot: Sendable, Equatable {
  public var presets: [Preset]
  public var selectedPreset: OptionID?
  /// Present only when band editing is available (Sony custom preset, Bose 3-band).
  public var bands: [Band]?

  public init(presets: [Preset] = [], selectedPreset: OptionID? = nil, bands: [Band]? = nil) {
    self.presets = presets
    self.selectedPreset = selectedPreset
    self.bands = bands
  }

  public struct Preset: Sendable, Equatable, Identifiable {
    public var id: OptionID
    public var isEditable: Bool
    public init(id: OptionID, isEditable: Bool = false) {
      self.id = id
      self.isEditable = isEditable
    }
  }

  public struct Band: Sendable, Equatable, Identifiable {
    public var id: OptionID
    public var range: LevelRange
    /// Sony reports a frequency; Bose reports Bass/Mid/Treble (no frequency). When nil,
    /// the UI labels the band from its id.
    public var frequencyHz: Int?
    public init(id: OptionID, range: LevelRange, frequencyHz: Int? = nil) {
      self.id = id
      self.range = range
      self.frequencyHz = frequencyHz
    }
  }
}

// MARK: - Audio / listening modes

public struct AudioModeSnapshot: Sendable, Equatable {
  public var modes: [Mode]
  public var selected: OptionID?

  public init(modes: [Mode] = [], selected: OptionID? = nil) {
    self.modes = modes
    self.selected = selected
  }

  public struct Mode: Sendable, Equatable, Identifiable {
    public var id: OptionID
    public var isEditable: Bool
    /// A parameter the mode holds and selects, such as Sony BGM's room. Nil when the
    /// mode has no sub-parameter.
    public var parameter: Parameter?
    public init(id: OptionID, isEditable: Bool = false, parameter: Parameter? = nil) {
      self.id = id
      self.isEditable = isEditable
      self.parameter = parameter
    }
  }

  /// A mode's sub-parameter — currently only a choice (Sony BGM room). A dedicated type
  /// so a mode selection and its parameter are not squeezed into one id.
  public struct Parameter: Sendable, Equatable {
    public var options: [OptionID]
    public var selected: OptionID?
    public init(options: [OptionID], selected: OptionID? = nil) {
      self.options = options
      self.selected = selected
    }
  }
}

// MARK: - Settings (toggle / choice / range)

/// A setting is one of three shapes, so a three-value choice (Bose spatial off/room/head)
/// or a four-value one (Bose sidetone off/high/med/low) is never crammed into a Bool.
/// Speak-to-chat carries its own detail, kept as a nested choice/range rather than a bare
/// `Int` that could not express "until released".
public enum SettingSnapshot: Sendable, Equatable {
  case toggle(isOn: Bool)
  case choice(options: [OptionID], selected: OptionID?)
  case range(LevelRange)
  case speakToChat(SpeakToChatSnapshot)
}

public struct SpeakToChatSnapshot: Sendable, Equatable {
  public var isOn: Bool
  public var sensitivity: [OptionID]
  public var selectedSensitivity: OptionID?
  /// Timeout options as opaque ids so "until released" is one of them, not an out-of-band
  /// sentinel on an `Int`.
  public var timeout: [OptionID]
  public var selectedTimeout: OptionID?

  public init(
    isOn: Bool,
    sensitivity: [OptionID] = [],
    selectedSensitivity: OptionID? = nil,
    timeout: [OptionID] = [],
    selectedTimeout: OptionID? = nil
  ) {
    self.isOn = isOn
    self.sensitivity = sensitivity
    self.selectedSensitivity = selectedSensitivity
    self.timeout = timeout
    self.selectedTimeout = selectedTimeout
  }
}

/// Multipoint is more than a toggle: it is a set of connection slots with one active.
/// Slots are opaque indices, never Bluetooth addresses or device names — those must not
/// enter the contract or its logs.
public struct MultipointSnapshot: Sendable, Equatable {
  public var isEnabled: Bool
  public var slots: [Slot]

  public init(isEnabled: Bool, slots: [Slot] = []) {
    self.isEnabled = isEnabled
    self.slots = slots
  }

  public struct Slot: Sendable, Equatable, Identifiable {
    /// An opaque index for the slot; not the paired device's address.
    public var id: Int
    public var isActive: Bool
    public init(id: Int, isActive: Bool) {
      self.id = id
      self.isActive = isActive
    }
  }
}
