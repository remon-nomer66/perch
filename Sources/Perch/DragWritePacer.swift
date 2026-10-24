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
/// A pointer that merely rests mid-gesture costs at most one early final, after which
/// further movement simply continues the drag.
@MainActor
struct DragWritePacer {
  nonisolated static let defaultDebounce: Duration = .milliseconds(90)
  nonisolated static let defaultSettle: Duration = .seconds(2)

  private static let log = Logger(subsystem: "dev.perch.mac", category: "DeviceWrite")

  private let debounce: Duration
  private let settle: Duration
  private var pending: Task<Void, Never>?

  init(
    debounce: Duration = DragWritePacer.defaultDebounce,
    settle: Duration = DragWritePacer.defaultSettle
  ) {
    self.debounce = debounce
    self.settle = settle
  }

  /// Takes one drag report. `write` is called with `isFinal` false for the paused-on
  /// intermediate value, and true for the settled one — at once for a release, after
  /// the quiet spell for a drag that was never released. Each report supersedes
  /// whatever the previous one still had scheduled.
  mutating func report(isFinal: Bool, write: @escaping @MainActor (_ isFinal: Bool) -> Void) {
    cancel()
    guard !isFinal else {
      write(true)
      return
    }
    let debounce = self.debounce
    let settle = self.settle
    pending = Task { @MainActor in
      // Checked after each sleep, not only through it: a sleep that already finished
      // can still be cancelled before this task resumes, and a stale value written
      // then would land after the release that superseded it.
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      write(false)
      try? await Task.sleep(for: settle)
      guard !Task.isCancelled else { return }
      Self.log.info("A drag ended without a release; finalised where it stopped")
      write(true)
    }
  }

  /// Drops whatever the last report still had scheduled: something else took the
  /// field over, and its own write is the one that should land.
  mutating func cancel() {
    pending?.cancel()
    pending = nil
  }
}
