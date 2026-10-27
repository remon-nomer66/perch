import Foundation

/// Keeps the main actor available while preview restoration and channel shutdown run.
/// A stalled restore must still initiate shutdown, and a stalled transport must not
/// prevent the application from replying to AppKit's termination request.
@MainActor
final class TerminationSequence {
  typealias Deadline = @MainActor () async throws -> Void

  private let restorationDeadline: Deadline
  private let completionDeadline: Deadline
  private(set) var hasStarted = false
  private(set) var hasCompleted = false
  private var restoration: Task<Void, Never>?
  private var restorationTimer: Task<Void, Never>?
  private var completionTimer: Task<Void, Never>?
  private var shutdown: Task<Void, Never>?
  private var stop: (@MainActor () async -> Void)?
  private var completion: (@MainActor () -> Void)?

  init(
    restorationDeadline: @escaping Deadline = { try await Task.sleep(for: .seconds(1)) },
    completionDeadline: @escaping Deadline = { try await Task.sleep(for: .seconds(2)) }
  ) {
    self.restorationDeadline = restorationDeadline
    self.completionDeadline = completionDeadline
  }

  func begin(
    restore: @escaping @MainActor () async -> Void,
    stop: @escaping @MainActor () async -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    guard !hasStarted else { return }
    hasStarted = true
    self.stop = stop
    self.completion = completion

    restoration = Task { [weak self] in
      await restore()
      await self?.stopAndFinish()
    }
    restorationTimer = Task { [weak self, restorationDeadline] in
      do { try await restorationDeadline() } catch { return }
      guard !Task.isCancelled else { return }
      await self?.stopAndFinish()
    }
    completionTimer = Task { [weak self, completionDeadline] in
      do { try await completionDeadline() } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.beginStop()
      self.finish()
    }
  }

  private func beginStop() {
    guard shutdown == nil, let stop else { return }
    shutdown = Task { await stop() }
    self.stop = nil
  }

  private func stopAndFinish() async {
    guard !hasCompleted else { return }
    beginStop()
    await shutdown?.value
    finish()
  }

  private func finish() {
    guard !hasCompleted else { return }
    hasCompleted = true
    restoration?.cancel()
    restorationTimer?.cancel()
    completionTimer?.cancel()
    let reply = completion
    completion = nil
    reply?()
  }
}
