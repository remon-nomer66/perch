import Foundation
import TandemCore

/// Whether a verification that threw is worth repeating.
///
/// Reaching the device and understanding it fail differently. A request that timed
/// out or a channel that closed may well succeed next time; a handshake answer of the
/// wrong shape comes back the same shape on every attempt, and retrying it only holds
/// the device's single control channel away from the hosts that can use it.
enum VerificationFailureKind: Equatable, Sendable {
  case transient
  case deterministic

  /// Only the handshake parser's own errors are deterministic: they are thrown after
  /// the device answered, about what it answered. Anything else — the session's
  /// request failures, the channel's, a cancellation, or a conformer's own error —
  /// stays transient, because retrying is the safe reading of a failure not known to
  /// be permanent.
  init(_ error: any Error) {
    self = error is TandemHandshakeError ? .deterministic : .transient
  }
}
