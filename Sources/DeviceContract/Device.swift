/// Brand-neutral vocabulary shared by every supported headset, so the UI can draw and
/// command a device without naming Sony or Bose. Each brand projects its own readings
/// onto these types through an adapter; nothing here depends on a brand.
///
/// Three concerns are kept apart on purpose (they were conflated in the first draft):
/// the connection *phase* (where the state machine is), the *verification trust* (is the
/// model known-good), and whether a write can land *right now*. A device can be readable
/// while not writable, verified while momentarily suspended, or recognised while gated
/// to read-only — none of which one flag can express.

public enum DeviceBrand: String, Sendable, Equatable, CaseIterable {
  case sony
  case bose
}

/// What the device is, filled in as it is read. `codec` is deliberately absent — the
/// negotiated codec is a live reading that changes during a session, not static
/// identity, so it belongs in the snapshot, not here.
public struct DeviceDescriptor: Sendable, Equatable {
  public var brand: DeviceBrand
  /// The product model name only (e.g. "WH-1000XM6"). Never the Bluetooth friendly name,
  /// which the user may have renamed — that would carry a personal label into the
  /// contract and its logs.
  public var modelName: String?
  public var firmwareVersion: String?

  public init(brand: DeviceBrand, modelName: String? = nil, firmwareVersion: String? = nil) {
    self.brand = brand
    self.modelName = modelName
    self.firmwareVersion = firmwareVersion
  }
}

/// Why a model is not fully verified, as a typed reason. The human-facing string is the
/// UI's job (Perch), not the session's: keeping localisation — and any device-derived
/// text — out of the contract and session layers protects both the layer boundary and
/// privacy.
public enum UnverifiedReason: Sendable, Equatable {
  case unknownModel
  case unverifiedFirmware
  case verificationFailed
}

/// Where the connection is. Complete enough to hold every state the Sony session machine
/// reaches, including the grace period after the Mac stops being the sound output.
public enum ConnectionPhase: Sendable, Equatable {
  case noDevice
  case connecting
  /// Connected; reading which features the device declares.
  case reading
  case ready
  /// Controllable, but the model is not on the verified list.
  case unverified(UnverifiedReason)
  /// Still connected and readable, but not the active sound output right now; the
  /// control channel is held through a short grace period. `resume` is what it returns
  /// to when the Mac is the output again.
  case suspended(resume: Resume)
  /// Another host holds the single control session.
  case contended
  /// Could not reach the device. `canRetry` is false while a backoff retry is still
  /// pending, true once the budget is spent (a manual retry then does something).
  case unreachable(canRetry: Bool)

  public enum Resume: Sendable, Equatable {
    case ready
    case unverified(UnverifiedReason)
  }

  /// Whether reads make sense — the panel can show live values.
  public var isReadable: Bool {
    switch self {
    case .ready, .unverified, .suspended: true
    case .noDevice, .connecting, .reading, .contended, .unreachable: false
    }
  }

  /// Whether a manual retry would do anything from here.
  public var canRetry: Bool {
    switch self {
    case .contended: true
    case .unreachable(let canRetry): canRetry
    case .noDevice, .connecting, .reading, .ready, .unverified, .suspended: false
    }
  }
}

/// Is the connected model known-good — separate from the phase and from momentary write
/// availability. A verified model can still be suspended; an unverified one can still be
/// written to with a caveat.
public enum VerificationTrust: Sendable, Equatable {
  case verified
  case unverified(UnverifiedReason)
}

/// Whether a write can land *right now*. Distinct from trust: suspended and read-only
/// both block writes without saying anything about whether the model is trusted.
public enum WriteAvailability: Sendable, Equatable {
  /// Writes go through.
  case writable
  /// Recognised, but writes are gated off (unverified model held read-only).
  case readOnly
  /// Temporarily not the sound output; writes wait for resume.
  case suspended
  /// No controllable device.
  case unavailable

  public var canWriteNow: Bool {
    switch self {
    case .writable: true
    case .readOnly, .suspended, .unavailable: false
    }
  }
}

/// How charged one enclosure is. `Bool?` could not tell "not charging" from "unknown",
/// and could not carry Sony's "charged" — so charge is its own four-state value.
public enum ChargeState: Sendable, Equatable {
  case unknown
  case notCharging
  case charging
  case charged
}

/// Charge as a list of enclosures, so a single figure, a left/right/case set, or a
/// device-numbered slot all use one shape. Percent is validated to 0...100 at
/// construction (out of range becomes nil rather than a wild value).
public struct BatteryReading: Sendable, Equatable {
  public enum Enclosure: Sendable, Equatable, Hashable {
    case single
    case left
    case right
    case caseEnclosure
    /// A slot the device numbers but does not name. An index, never a label — PII-free.
    case other(index: Int)
  }

  public struct Cell: Sendable, Equatable {
    public var enclosure: Enclosure
    public private(set) var percent: Int?
    public var charge: ChargeState

    public init(enclosure: Enclosure, percent: Int? = nil, charge: ChargeState = .unknown) {
      self.enclosure = enclosure
      // A percent outside 0...100 is a parse error, not a reading; drop it rather than
      // draw a wild bar.
      self.percent = percent.flatMap { (0...100).contains($0) ? $0 : nil }
      self.charge = charge
    }
  }

  public private(set) var cells: [Cell]

  /// Cells are kept unique by enclosure, first write winning, insertion order preserved —
  /// so a duplicate or reordering from the wire cannot make two readings compare unequal
  /// when they mean the same thing.
  public init(cells: [Cell] = []) {
    var seen: Set<Enclosure> = []
    self.cells = cells.filter { seen.insert($0.enclosure).inserted }
  }

  public static let unknown = BatteryReading()
}
