/// The thin, brand-neutral vocabulary the *shared* parts of the app need: the closed
/// notch bar and the menu bar icon, which look the same whatever headset is connected,
/// and the routing that picks which brand's panel to open.
///
/// Everything past the closed bar is brand-specific by design — Sony and Bose each have
/// their own expanded panel, their own feature types, their own session. Forcing their
/// controls into one shared vocabulary was the wrong path (it made the abstraction fight
/// both devices); this module deliberately stays at the closed-bar altitude and no
/// deeper. A device's features are described by its own brand's types, not here.

public enum DeviceBrand: String, Sendable, Equatable, CaseIterable {
  case sony
  case bose
}

/// How charged one enclosure is. `Bool?` could not tell "not charging" from "unknown",
/// nor carry "charged" — so charge is its own four-state value.
public enum ChargeState: Sendable, Equatable {
  case unknown
  case notCharging
  case charging
  case charged
}

/// Charge as a list of enclosures, so a single figure, a left/right/case set, or a
/// device-numbered slot all use one shape. Percent is validated to 0...100 at
/// construction; cells are unique by enclosure with insertion order kept, so a duplicate
/// or reordering from the wire cannot make equal readings compare unequal.
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

  public init(cells: [Cell] = []) {
    var seen: Set<Enclosure> = []
    self.cells = cells.filter { seen.insert($0.enclosure).inserted }
  }

  public static let unknown = BatteryReading()
}

/// What the shared closed notch bar and the menu bar icon draw, and which brand's panel
/// to route to. Nothing here describes a feature — the expanded panel is brand-specific
/// and reads its device's own types directly.
public struct DeviceHeadline: Sendable, Equatable {
  public var brand: DeviceBrand
  /// The product model name only (e.g. "WH-1000XM6" / "QC Ultra 2"). Never the Bluetooth
  /// friendly name, which the user may have renamed — that would carry a personal label
  /// into the closed bar and its logs.
  public var modelName: String?
  public var battery: BatteryReading
  /// Drives the menu bar icon's connected colour and whether the closed bar shows
  /// content. The brand panel decides everything finer.
  public var isControllable: Bool

  public init(
    brand: DeviceBrand,
    modelName: String? = nil,
    battery: BatteryReading = .unknown,
    isControllable: Bool = false
  ) {
    self.brand = brand
    self.modelName = modelName
    self.battery = battery
    self.isControllable = isControllable
  }
}
