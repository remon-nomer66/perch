/// The transport-selection port and the single-session ownership rule, kept in the
/// dependency-free contract so a session target can use them without reaching up into the
/// executable's settings store.

public enum TransportKind: Sendable, Equatable {
  case classicRFCOMM
  case ble
}

/// Identifies which *model* a remembered transport preference is for — never which unit.
/// Derived from brand + product id, so it carries no Bluetooth address, no CBPeripheral
/// UUID, and no device name. Two units of the same model share one key on purpose.
public struct DevicePreferenceKey: Sendable, Equatable, Hashable {
  public let raw: String
  public init(brand: DeviceBrand, productID: String) {
    self.raw = "\(brand.rawValue):\(productID)"
  }
}

/// A port for remembering which transport worked for a model, so the next connection can
/// go straight to it. The executable provides a `UserDefaults`-backed adapter; the
/// session target depends only on this protocol. Preferences are advisory — a stored
/// choice that stops working is re-decided by the live probe, so no explicit expiry is
/// needed, only "try the remembered one first, fall back on failure".
public protocol TransportPreferenceStore: Sendable {
  func preferredTransport(for key: DevicePreferenceKey) async -> TransportKind?
  func rememberTransport(_ kind: TransportKind, for key: DevicePreferenceKey) async
}

/// Owns the one live control session and guarantees the single-session rule: the headset
/// exposes exactly one control channel, so a brand or transport switch must fully close
/// the old session before opening the new one. The UI-facing `DeviceControl` cannot make
/// that guarantee on its own — the supervisor is the single place a session is opened or
/// closed.
///
/// Defined here as the contract; the concrete supervisor lives above the brand sessions.
public protocol DeviceSessionSupervisor: Actor {
  /// The current session, or nil when nothing is connected.
  var current: (any DeviceControl)? { get async }
  /// Closes any current session, then opens one for the device just discovered. The
  /// close must complete before the open begins.
  func switchTo(brand: DeviceBrand) async
  /// Closes the current session and holds none.
  func closeCurrent() async
}
