/// Brand-neutral vocabulary shared by every supported headset, so the UI can draw and
/// command a device without naming Sony or Bose. Each brand's core projects its own
/// readings onto these types through an adapter; nothing here depends on a brand.
///
/// This is the stable foundation frozen in the device-contract stage. The richer
/// per-feature snapshot and command detail types (documented in
/// `docs/bose-device-contract.md`) are materialised later, in the vertical slice, so a
/// single feature can be carried end to end before the whole UI moves off Sony types.

public enum DeviceBrand: String, Sendable, Equatable, CaseIterable {
  case sony
  case bose
}

/// What the device says it is, filled in as it is read. Every field is optional because
/// the name and firmware arrive after the connection, not with it.
public struct DeviceIdentity: Sendable, Equatable {
  public var brand: DeviceBrand
  public var modelName: String?
  public var firmwareVersion: String?
  /// The negotiated audio codec, when the device reports one.
  public var codec: String?

  public init(
    brand: DeviceBrand,
    modelName: String? = nil,
    firmwareVersion: String? = nil,
    codec: String? = nil
  ) {
    self.brand = brand
    self.modelName = modelName
    self.firmwareVersion = firmwareVersion
    self.codec = codec
  }
}

/// The connection as the UI needs to see it — brand-neutral, mirroring the meaning of
/// Sony's `DeviceSummary.Status` without any Sony type. A brand's session maps its own
/// state machine onto this.
public enum ConnectionStatus: Sendable, Equatable {
  case noDevice
  case connecting
  /// Connected; reading which features the device declares.
  case reading
  case ready
  /// Controllable, but the model is not on the verified list — controls work while a
  /// caveat stays on screen.
  case unverified(caveat: String)
  /// Recognised, but writes are gated off; only reading is allowed.
  case readOnly(caveat: String)
  /// Another host holds the single control session. Recoverable with `retry`.
  case contended
  case unreachable

  /// Whether controls should be offered at all. Read-only and the transient states
  /// are not controllable; writes are further gated by `WriteTrust`.
  public var isControllable: Bool {
    switch self {
    case .ready, .unverified: true
    case .noDevice, .connecting, .reading, .readOnly, .contended, .unreachable: false
    }
  }
}

/// Capability (which features exist) is kept separate from whether writing to them is
/// allowed. A recognised-but-unverified device may declare a feature yet refuse writes.
public enum WriteTrust: Sendable, Equatable {
  /// Verified model; writes go through.
  case trusted
  /// Recognised but the firmware or model is unverified; writes land with a caveat.
  case experimental
  /// Writes are gated off; the device is read-only.
  case readOnly

  public var allowsWrites: Bool {
    switch self {
    case .trusted, .experimental: true
    case .readOnly: false
    }
  }
}

/// Charge as a list of components, so a single figure, a left/right/case set, or a
/// future multi-component earbud all use one shape. Percent and charging are optional
/// because a device may report one enclosure and not another.
public struct BatteryReading: Sendable, Equatable {
  public enum Component: Sendable, Equatable, Hashable {
    case single
    case left
    case right
    case caseEnclosure
    /// An enclosure a device labels itself, for shapes not known ahead of time.
    case labeled(String)
  }

  public struct Cell: Sendable, Equatable {
    public var component: Component
    public var percent: Int?
    public var isCharging: Bool?

    public init(component: Component, percent: Int? = nil, isCharging: Bool? = nil) {
      self.component = component
      self.percent = percent
      self.isCharging = isCharging
    }
  }

  public var cells: [Cell]

  public init(cells: [Cell] = []) {
    self.cells = cells
  }

  public static let unknown = BatteryReading(cells: [])
}

/// The feature vocabulary. Capability is the set of features a device declares — the
/// basis for showing or hiding UI, exactly as the app already does for Sony.
public enum DeviceFeature: String, Sendable, Equatable, CaseIterable, Hashable {
  case noiseControl
  case equalizer
  /// Sony's listening modes and Bose's audio modes both land here.
  case audioMode
  case speakToChat
  case sidetone
  case spatialAudio
  case multipoint
  case autoPause
  case buttons
}

/// What the device declares plus whether it may be written to — the two kept apart on
/// purpose (a device can offer a feature while refusing writes).
public struct DeviceCapabilities: Sendable, Equatable {
  public var features: Set<DeviceFeature>
  public var writeTrust: WriteTrust

  public init(features: Set<DeviceFeature> = [], writeTrust: WriteTrust = .readOnly) {
    self.features = features
    self.writeTrust = writeTrust
  }

  public func declares(_ feature: DeviceFeature) -> Bool {
    features.contains(feature)
  }
}
