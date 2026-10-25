import Foundation

/// Orders every write a session makes on one channel, and bounds how long each may
/// take.
///
/// Acknowledgements, requests, and drag steps are produced in different places but
/// must reach the device in the order the session produced them, so each write waits
/// for the one queued before it. Waiting is what makes a stalled write dangerous —
/// the transport's `writeSync` blocks while the remote withholds flow-control credit —
/// so each write is also given a deadline after which it is reported as timed out
/// instead of being waited on.
struct ChannelWriteChain: Sendable {
  typealias Outcome = Task<Result<Void, ChannelFailure>, Never>

  private let tail: Outcome?

  init() {
    tail = nil
  }

  private init(tail: Outcome) {
    self.tail = tail
  }

  /// Queues `data` behind every write already queued. Returns the chain that now ends
  /// with it and the write's outcome, which the caller may await or drop: the write
  /// goes out either way.
  func appending(
    _ data: Data,
    to channel: any TandemChannel,
    within limit: Duration
  ) -> (chain: ChannelWriteChain, outcome: Outcome) {
    let previous = tail
    let outcome = Task {
      _ = await previous?.value
      return await Self.write(data, to: channel, within: limit)
    }
    return (ChannelWriteChain(tail: outcome), outcome)
  }

  /// Races the write against its deadline without waiting for the loser. A task group
  /// cannot do this: it waits for every child, and the transport's write does not
  /// notice cancellation, so a stalled write would hold the group open with it.
  private static func write(
    _ data: Data,
    to channel: any TandemChannel,
    within limit: Duration
  ) async -> Result<Void, ChannelFailure> {
    await withCheckedContinuation { continuation in
      let settle = SettleOnce(continuation)
      let deadline = Task {
        do {
          try await Task.sleep(for: limit)
        } catch {
          return
        }
        settle(.failure(.writeTimedOut))
      }
      Task {
        let result: Result<Void, ChannelFailure>
        do {
          try await channel.write(data)
          result = .success(())
        } catch let failure as ChannelFailure {
          result = .failure(failure)
        } catch {
          result = .failure(.closed)
        }
        deadline.cancel()
        settle(result)
      }
    }
  }
}

/// Resumes a continuation with whichever result arrives first and ignores the rest,
/// since resuming one twice traps.
private final class SettleOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Result<Void, ChannelFailure>, Never>?

  init(_ continuation: CheckedContinuation<Result<Void, ChannelFailure>, Never>) {
    self.continuation = continuation
  }

  func callAsFunction(_ result: Result<Void, ChannelFailure>) {
    let pending = lock.withLock { () -> CheckedContinuation<Result<Void, ChannelFailure>, Never>? in
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(returning: result)
  }
}
