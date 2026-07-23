import Foundation
import TandemCore
import TandemSession

/// What the interface knows about the device right now.
///
/// Deliberately explicit about not knowing. An interface that quietly shows plausible
/// values for a device it never read is worse than one that says it has nothing.
struct DeviceSummary: Equatable {
  enum Status: Equatable {
    case noDevice
    case connecting
    case reading
    /// Usable, but the encodings sent to it have never been checked against this
    /// model. Controls work; the caveat stays on screen.
    case unverified(caveat: String)
    case ready
    /// Another host holds the control session.
    case takenByAnotherDevice
    case unreachable
  }

  var status: Status = .noDevice
  /// Known as soon as the device has been read, whatever the status became.
  var modelName: String?
  var firmwareVersion: String?
  var codec: String?
  /// Whether the session accepts writes right now. A rejected model stays readable —
  /// controllable in status terms — while every control write is refused, and the
  /// interface must say so rather than show controls that silently do nothing.
  var acceptsWrites = true

  var isControllable: Bool {
    switch status {
    case .ready, .unverified: true
    default: false
    }
  }

  var caveat: String? {
    // Read-only wins over the unverified warning: "commands may misbehave" is moot
    // when no command is sent at all.
    if isControllable, !acceptsWrites {
      return L(
        "この機種は現在読み取りのみ対応しています(操作は送信されません)",
        "This model is currently read-only; controls are not sent."
      )
    }
    if case .unverified(let text) = status { return text }
    return nil
  }

  static func status(
    for phase: SessionState.Phase,
    reason: TandemDeviceVerificationFailure?
  ) -> Status {
    switch phase {
    case .released, .sleeping:
      return .noDevice
    case .connecting:
      return .connecting
    case .verifying, .recovering:
      return .reading
    case .contended:
      return .takenByAnotherDevice
    case .retryWaiting, .retryExhausted:
      return .unreachable
    case .unverified:
      return .unverified(caveat: Self.caveat(reason))
    case .ready:
      return .ready
    case .suspended(let resume):
      return resume == .ready ? .ready : .unverified(caveat: Self.caveat(reason))
    }
  }

  /// States the risk in the terms that matter: the encodings came from a different
  /// model, and a wrong result is detected only after the fact.
  private static func caveat(_ reason: TandemDeviceVerificationFailure?) -> String {
    L(
      "この機種では動作を確認していません。"
        + "他機種向けの指示を送るため、意図しない設定になることがあります。",
      "Operation has not been verified on this model. "
        + "Commands meant for other models are sent, so unintended settings can result."
    )
  }
}

/// Softens the unreachable status for display.
///
/// Taking the headset off and on again costs the session about a second of retry, and
/// during it the raw phase passes through the retry states — shown directly, "could
/// not connect" flashes on every re-wear. Presentation-side only: unreachable is shown
/// once it has held for a few seconds, and reads as "connecting" until then. The
/// session itself is not touched.
struct UnreachableDebounce {
  /// How long unreachable must hold before it is believed enough to show.
  private let holdOff: Duration
  private var since: ContinuousClock.Instant?

  init(holdOff: Duration = .seconds(3)) {
    self.holdOff = holdOff
  }

  mutating func present(
    _ status: DeviceSummary.Status,
    now: ContinuousClock.Instant = .now
  ) -> DeviceSummary.Status {
    guard status == .unreachable else {
      since = nil
      return status
    }
    let start = since ?? now
    since = start
    return now - start >= holdOff ? .unreachable : .connecting
  }
}
