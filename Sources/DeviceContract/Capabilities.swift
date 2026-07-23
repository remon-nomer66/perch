/// What a device can do, split along the axes the first draft ran together: a feature
/// can be *declared* by the device yet not *readable* (the read failed), or readable yet
/// not *writable right now* (suspended, gated, or a per-feature lock like sidetone's
/// control-enabled flag or a Bose mode slot that is not editable).

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

/// The read state of a feature's value, so the UI can tell "the device does not have
/// this" from "we have not read it yet" from "the read failed". `nil` in a snapshot
/// alone could not make these distinctions.
public enum FeatureReadState: Sendable, Equatable {
  /// The device does not declare this feature.
  case undeclared
  /// Declared, but no value has arrived yet.
  case loading
  /// A current value is present.
  case fresh
  /// A value was read before but the last refresh failed; the shown value may be stale.
  case stale
  /// Declared but the read failed and no value was ever obtained.
  case failed
}

/// Whether a specific feature may be written to now — finer than the device-wide
/// `WriteAvailability`. Sidetone can be present but control-disabled; a Bose mode slot
/// can be a locked firmware preset.
public enum FeatureWriteState: Sendable, Equatable {
  case writable
  case disabled
  case readOnly
}

public struct FeatureAvailability: Sendable, Equatable {
  public var read: FeatureReadState
  public var write: FeatureWriteState

  public init(read: FeatureReadState, write: FeatureWriteState) {
    self.read = read
    self.write = write
  }

  public static let undeclared = FeatureAvailability(read: .undeclared, write: .readOnly)
}

/// What the device declares plus, per feature, its read/write state. Device-wide
/// verification trust and momentary write availability live on the state; this is the
/// per-feature layer.
public struct DeviceCapabilities: Sendable, Equatable {
  public var trust: VerificationTrust
  public var writeAvailability: WriteAvailability
  private var perFeature: [DeviceFeature: FeatureAvailability]

  public init(
    trust: VerificationTrust = .verified,
    writeAvailability: WriteAvailability = .unavailable,
    features: [DeviceFeature: FeatureAvailability] = [:]
  ) {
    self.trust = trust
    self.writeAvailability = writeAvailability
    self.perFeature = features
  }

  /// A feature is declared unless its read state says undeclared.
  public func declares(_ feature: DeviceFeature) -> Bool {
    availability(of: feature).read != .undeclared
  }

  public func availability(of feature: DeviceFeature) -> FeatureAvailability {
    perFeature[feature] ?? .undeclared
  }

  /// Writing to a feature needs the device to allow writes now *and* the feature itself
  /// to be writable — both gates, not one.
  public func canWrite(_ feature: DeviceFeature) -> Bool {
    writeAvailability.canWriteNow && availability(of: feature).write == .writable
  }

  public var declaredFeatures: Set<DeviceFeature> {
    Set(perFeature.keys.filter { perFeature[$0]?.read != .undeclared })
  }
}
