import Foundation
import TandemCore
import os

/// What the session writes to the unified log: how its phase moved, and why things
/// failed.
///
/// Nothing identifying is logged — no address, no unit or model name, no firmware
/// string — only the protocol-level shape of what happened. Every line is built from
/// the names below, which drop the identifying payloads before anything is formatted,
/// so the strings can be logged as public and a log attached to a report still reads.
enum SessionLog {
  private static let log = Logger(subsystem: "dev.perch.mac", category: "session")

  static func transition(from previous: SessionState, to next: SessionState, on event: SessionEvent) {
    guard previous.phase != next.phase else { return }
    let from = name(of: previous.phase)
    let to = name(of: next.phase)
    let cause = name(of: event)
    log.notice(
      "\(from, privacy: .public) → \(to, privacy: .public) on \(cause, privacy: .public), failures \(next.failureCount, privacy: .public)"
    )
  }

  static func openFailed(_ error: any Error) {
    let cause = reason(error)
    log.error("open failed: \(cause, privacy: .public)")
  }

  static func verificationFailed(_ error: any Error, kind: VerificationFailureKind) {
    let cause = reason(error)
    let verdict = kind == .deterministic ? "not retrying" : "retrying"
    log.error("verification failed, \(verdict, privacy: .public): \(cause, privacy: .public)")
  }

  /// Which request went unanswered is what tells a declared-but-silent function apart
  /// from a session that stopped answering altogether.
  static func unanswered(_ label: String, faultsSession: Bool) {
    let consequence = faultsSession ? "rebuilding the session" : "session kept"
    log.notice("request \(label, privacy: .public) unanswered; \(consequence, privacy: .public)")
  }

  static func writeStalled() {
    log.error("a write overran its bound; rebuilding the session")
  }

  // MARK: - Names

  static func name(of event: SessionEvent) -> String {
    switch event {
    case .defaultOutputChanged(let device): "defaultOutputChanged(\(presence(device)))"
    case .didWake(let device): "didWake(\(presence(device)))"
    case .channelOpened(let attempt): "channelOpened(attempt \(attempt.value))"
    case .channelFailed(let attempt): "channelFailed(attempt \(attempt.value))"
    case .channelClosedUnexpectedly(let attempt): "channelClosedUnexpectedly(attempt \(attempt.value))"
    case .controlContended(let attempt): "controlContended(attempt \(attempt.value))"
    case .sessionFault(let fault): "sessionFault(\(fault))"
    case .channelClosedByUs, .verificationSucceeded, .verificationRejected,
      .verificationFailedTransient, .verificationFailedPermanently, .sessionProvedStable,
      .graceExpired, .backoffExpired, .bluetoothDisconnected, .willSleep, .manualRetry,
      .manualRelease:
      "\(event)"
    }
  }

  static func name(of phase: SessionState.Phase) -> String {
    switch phase {
    case .suspended(let resume): "suspended(\(resume))"
    case .sleeping(.reconnect): "sleeping(reconnect)"
    case .sleeping(.blocked(let refusal)): "sleeping(blocked: \(refusal))"
    case .released, .connecting, .verifying, .ready, .contended, .retryWaiting, .retryExhausted,
      .incompatible, .unverified, .recovering:
      "\(phase)"
    }
  }

  /// The session's own failure types are spelled out case by case. Anything else is
  /// named by its type alone: its description could hold anything, a unit name
  /// included.
  static func reason(_ error: any Error) -> String {
    switch error {
    case let failure as ChannelFailure: "\(failure)"
    case let failure as SessionRequestFailure:
      switch failure {
      case .notReady: "notReady"
      case .failed(let request): "failed(\(request))"
      case .channel(let channel): "channel(\(channel))"
      }
    case let failure as TandemHandshakeError: failure.description
    case is CancellationError: "cancelled"
    default: String(describing: type(of: error))
    }
  }

  /// Command and inquiry: enough to say which function went quiet, nothing more.
  static func label(ofRequest payload: Data) -> String {
    payload.prefix(2).map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  private static func presence(_ device: DeviceIdentity?) -> String {
    device == nil ? "none" : "device"
  }
}
