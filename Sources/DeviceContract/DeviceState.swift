/// One atomic view of the device, read in a single hop. The first draft's four separate
/// getters (identity/status/capabilities/snapshot) could each land on a different moment
/// across `await`s; a single `DeviceState` cannot tear. `revision` bumps on every refresh
/// so a command can name the state it was built from, and a session can reject one built
/// against a view the device has since moved past.
public struct DeviceState: Sendable, Equatable {
  public var revision: UInt64
  public var descriptor: DeviceDescriptor
  public var phase: ConnectionPhase
  public var capabilities: DeviceCapabilities
  public var battery: BatteryReading

  public var noiseControl: NoiseControlSnapshot?
  public var equalizer: EqualizerSnapshot?
  public var audioMode: AudioModeSnapshot?
  public var spatialAudio: SettingSnapshot?
  public var sidetone: SettingSnapshot?
  public var speakToChat: SettingSnapshot?
  public var autoPause: SettingSnapshot?
  public var multipoint: MultipointSnapshot?

  public init(
    revision: UInt64 = 0,
    descriptor: DeviceDescriptor,
    phase: ConnectionPhase = .noDevice,
    capabilities: DeviceCapabilities = DeviceCapabilities(),
    battery: BatteryReading = .unknown,
    noiseControl: NoiseControlSnapshot? = nil,
    equalizer: EqualizerSnapshot? = nil,
    audioMode: AudioModeSnapshot? = nil,
    spatialAudio: SettingSnapshot? = nil,
    sidetone: SettingSnapshot? = nil,
    speakToChat: SettingSnapshot? = nil,
    autoPause: SettingSnapshot? = nil,
    multipoint: MultipointSnapshot? = nil
  ) {
    self.revision = revision
    self.descriptor = descriptor
    self.phase = phase
    self.capabilities = capabilities
    self.battery = battery
    self.noiseControl = noiseControl
    self.equalizer = equalizer
    self.audioMode = audioMode
    self.spatialAudio = spatialAudio
    self.sidetone = sidetone
    self.speakToChat = speakToChat
    self.autoPause = autoPause
    self.multipoint = multipoint
  }
}

/// What the UI asks the device to do, as gestures that carry the opaque ids the snapshot
/// handed out — never array indices. `isFinal` marks the settled value of a drag and
/// hints that a read-back should confirm it; intermediate drag values are non-final.
public enum DeviceCommand: Sendable, Equatable {
  case selectNoiseOption(OptionID)
  /// Drag the continuous noise axis, or a mode's level, to `value`.
  case setNoiseLevel(Int, isFinal: Bool)
  case setNoiseSwitch(NoiseSwitch, Bool)
  case selectEqualizerPreset(OptionID)
  case setEqualizerBand(OptionID, Int, isFinal: Bool)
  case selectAudioMode(OptionID)
  case selectModeParameter(feature: DeviceFeature, OptionID)
  case setSetting(DeviceFeature, SettingValue)
  case setMultipointEnabled(Bool)
  case activateMultipointSlot(Int)

  public enum NoiseSwitch: Sendable, Equatable {
    case voiceFocus
    case windReduction
    case noiseCancellingEnabled
    case adaptive
  }

  public enum SettingValue: Sendable, Equatable {
    case toggle(Bool)
    case choice(OptionID)
    case level(Int, isFinal: Bool)
  }
}

/// A command paired with the state revision it was built from, so a session can refuse a
/// command aimed at a view the device has moved past.
public struct RevisionedCommand: Sendable, Equatable {
  public var basedOnRevision: UInt64
  public var command: DeviceCommand

  public init(basedOnRevision: UInt64, command: DeviceCommand) {
    self.basedOnRevision = basedOnRevision
    self.command = command
  }
}

/// The brand-neutral outcomes a write can have. The Sony session already distinguishes
/// these; the contract must be able to carry them across brands rather than collapse
/// everything into a bare `throws`.
public enum DeviceControlError: Error, Sendable, Equatable {
  /// Writes are gated off for this device or feature right now.
  case notPermitted
  /// The device does not support this command.
  case unsupported
  /// The write was sent but the device kept a different value. `observedLevel` carries
  /// what it actually holds, when that is a level; otherwise the caller re-reads.
  case notApplied(observedLevel: Int?)
  /// The command was built from a state the device has since moved past.
  case staleSnapshot
  case sessionFailure
  case transportFailure
}

/// The common face of a live device session, whatever the brand. Sony's `SessionCoordinator`
/// and Bose's session both conform. One atomic `state` getter, not several; `apply` takes
/// a revisioned command and throws a typed error.
public protocol DeviceControl: Actor {
  var state: DeviceState { get async }
  func apply(_ command: RevisionedCommand) async throws
  /// A manual retry, meaningful only while `state.phase.canRetry`.
  func retry() async
}
