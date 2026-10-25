import os

/// Paces the device writes of one dragged control.
///
/// A drag reports every pointer move, far more often than the headset should be
/// written to. Intermediate positions are sent once the pointer pauses for
/// `debounce`, as non-final, so the listener hears the change without the channel
/// flooding; the release is sent at once as final, which is what gets read back.
///
/// A release does not always come. The panel can close under the finger — the pointer
/// leaving the notch takes the view, and its gesture, away mid-drag — and SwiftUI then
/// never reports the end. The device was left holding a value it was told was still
/// moving, and the field's adjustment guard, which only the final read-back lifts,
/// kept the panel deaf to the device. So a drag that reports nothing for `settle`
/// after its last intermediate is taken as released where it stopped, and finalised.
///
/// A pointer held still mid-gesture for `settle` is finalised early the same way —
/// once for every such rest, as many rests as there are — and moving on simply
/// continues the drag. A release that follows a rest without any movement in between
/// would only send that final again; `repeatsItsOwnFinal` lets the caller skip it.
///
/// A class rather than a value: the quiet spell's task records that it finalised, and
/// a copy captured by that task could not tell the caller.
@MainActor
final class DragWritePacer {
  nonisolated static let defaultDebounce: Duration = .milliseconds(90)
  nonisolated static let defaultSettle: Duration = .seconds(2)

  private static let log = Logger(subsystem: "dev.perch.mac", category: "DeviceWrite")

  private let debounce: Duration
  private let settle: Duration
  private let sleep: @MainActor (Duration) async -> Void
  private var pending: Task<Void, Never>?

  /// True once the quiet spell finalised the drag where it stopped, until the next
  /// report or cancel.
  private(set) var hasSettledOnItsOwn = false

  /// `sleep` times both waits; tests pass one they advance by hand.
  init(
    debounce: Duration = DragWritePacer.defaultDebounce,
    settle: Duration = DragWritePacer.defaultSettle,
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.debounce = debounce
    self.settle = settle
    self.sleep = sleep
  }

  /// Whether a release would only repeat the final the quiet spell already sent: the
  /// drag settled on its own and the value has not moved since. Nothing about the
  /// device changes for sending it twice — the headset just re-applies the effect.
  nonisolated static func repeatsSettledFinal(
    isFinal: Bool, settledOnItsOwn: Bool, valueUnchanged: Bool
  ) -> Bool {
    isFinal && settledOnItsOwn && valueUnchanged
  }

  /// `repeatsSettledFinal` for this drag. Asked before the report takes a guard token:
  /// a skipped release must take none, or nothing would ever lift it.
  func repeatsItsOwnFinal(isFinal: Bool, valueUnchanged: Bool) -> Bool {
    Self.repeatsSettledFinal(
      isFinal: isFinal, settledOnItsOwn: hasSettledOnItsOwn, valueUnchanged: valueUnchanged
    )
  }

  /// Takes one drag report. `write` is called with `isFinal` false for the paused-on
  /// intermediate value, and true for the settled one — at once for a release, after
  /// the quiet spell for a drag that was never released. Each report supersedes
  /// whatever the previous one still had scheduled.
  func report(isFinal: Bool, write: @escaping @MainActor (_ isFinal: Bool) -> Void) {
    cancel()
    guard !isFinal else {
      write(true)
      return
    }
    let debounce = self.debounce
    let settle = self.settle
    let sleep = self.sleep
    pending = Task { @MainActor [weak self] in
      // Checked after each sleep, not only through it: a sleep that already finished
      // can still be cancelled before this task resumes, and a stale value written
      // then would land after the release that superseded it.
      await sleep(debounce)
      guard !Task.isCancelled else { return }
      write(false)
      await sleep(settle)
      guard !Task.isCancelled else { return }
      Self.log.info("A drag ended without a release; finalised where it stopped")
      self?.hasSettledOnItsOwn = true
      write(true)
    }
  }

  /// Drops whatever the last report still had scheduled: something else took the
  /// field over, and its own write is the one that should land.
  func cancel() {
    pending?.cancel()
    pending = nil
    hasSettledOnItsOwn = false
  }
}
