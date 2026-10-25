import Dispatch
import os

/// Runs a blocking call — a synchronous round trip to coreaudiod — off the main actor,
/// with a time limit.
///
/// A call that has not come back in time answers nil ("no answer"). While it is still
/// out, further calls answer nil at once instead of queueing behind it, so a daemon
/// that hangs costs one blocked thread, not one more per tick.
final class BlockingCallGate<Value: Sendable>: Sendable {
  private let queue: DispatchQueue
  private let timeout: Duration
  private let busy = OSAllocatedUnfairLock(initialState: false)

  init(label: String, timeout: Duration) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    self.timeout = timeout
  }

  /// The answer of `work`, or nil when it did not come back within the time limit (or
  /// an earlier call is still out).
  func run(_ work: @escaping @Sendable () -> Value) async -> Value? {
    let claimed = busy.withLock { busy -> Bool in
      guard !busy else { return false }
      busy = true
      return true
    }
    guard claimed else { return nil }
    let deadline = DispatchTime.now() + Self.seconds(timeout)
    return await withCheckedContinuation { continuation in
      let reply = Reply(continuation)
      queue.async { [busy] in
        let value = work()
        busy.withLock { $0 = false }
        reply.send(value)
      }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) {
        reply.send(nil)
      }
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) * 1e-18
  }
}

/// Resumes a continuation exactly once: with the answer or the timeout, whichever lands
/// first.
private final class Reply<Value: Sendable>: Sendable {
  private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value?, Never>?>

  init(_ continuation: CheckedContinuation<Value?, Never>) {
    self.continuation = OSAllocatedUnfairLock(initialState: continuation)
  }

  func send(_ value: Value?) {
    let pending = continuation.withLock { pending -> CheckedContinuation<Value?, Never>? in
      defer { pending = nil }
      return pending
    }
    pending?.resume(returning: value)
  }
}
