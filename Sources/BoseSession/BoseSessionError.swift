import BoseCore
import Foundation

/// Why a single request, drain, or write-then-poll ended without a usable result.
///
/// A device `ERROR` frame becomes a typed `device` / `deviceUnknown` case carrying the
/// `BmapErrorCode` (or the raw byte for a code this app does not name), so callers can
/// branch on, say, `runtime` (a state the device forbids) versus a transport problem.
/// Per the frozen spec an `ERROR` is proof the link works, so it is never conflated
/// with `channel`.
public enum BoseRequestError: Error, Equatable, Sendable {
  /// The device answered with a recognised `ERROR` code.
  case device(BmapErrorCode)
  /// The device answered with an `ERROR` whose code this app does not name. The raw
  /// byte is preserved so an unrecognised failure is still visibly a failure.
  case deviceUnknown(rawCode: UInt8?)
  /// No terminal answer arrived before the response deadline.
  case timedOut
  /// A drain expected at least one related answer and got none before its first-
  /// response deadline.
  case noResponse
  /// A write-then-poll exhausted its read-backs without the device reporting the value
  /// that was written. The frame carried is the last read-back, i.e. what the device
  /// actually holds.
  case notApplied(BmapFrame)
  /// The request's task was cancelled while it was waiting.
  case cancelled
  /// The session was torn down (local close or the transport dropping) underneath the
  /// request.
  case sessionClosed
  /// The transport failed while sending.
  case channel(BmapChannelFailure)
}

/// Why establishing the session failed.
public enum BoseSessionError: Error, Equatable, Sendable {
  /// The connect-time init was resent up to the cap without the device ever answering.
  case connectFailed(attempts: Int)
  /// The session was closed before or during connect.
  case sessionClosed
  /// Connect was cancelled before the device answered.
  case cancelled
  /// The transport failed during connect. Carries the underlying cause rather than
  /// reporting a spurious "resent to the cap" that never happened.
  case channel(BmapChannelFailure)
}
