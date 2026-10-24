import Testing

@testable import Perch

// How one dragged control's reports become device writes: intermediate positions are
// sent once the pointer pauses, the release is sent at once as final — and a drag whose
// release never arrives (the panel closed under the finger) is finalised on its own
// after a quiet spell, rather than leaving the device mid-drag and the field guarded.

/// The writes the pacer asked for, as "<report>:<final|intermediate>".
@MainActor
private final class Writes {
  var log: [String] = []

  func recorder(_ name: String) -> @MainActor (Bool) -> Void {
    { [weak self] isFinal in self?.log.append("\(name):\(isFinal ? "final" : "intermediate")") }
  }

  /// Yields to the pacer's tasks until `condition` holds, bounded so a broken pacer
  /// fails the test instead of hanging it.
  func wait(within limit: Duration = .seconds(2), until condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
@Test("A release is written at once, as final")
func releaseIsWrittenAtOnce() {
  let writes = Writes()
  var pacer = DragWritePacer(debounce: .seconds(30), settle: .seconds(30))
  pacer.report(isFinal: true, write: writes.recorder("a"))
  #expect(writes.log == ["a:final"])
}

@MainActor
@Test("Reports in quick succession send only the last, once the pointer pauses")
func intermediatesAreDebounced() async {
  let writes = Writes()
  var pacer = DragWritePacer(debounce: .milliseconds(30), settle: .seconds(30))
  pacer.report(isFinal: false, write: writes.recorder("a"))
  pacer.report(isFinal: false, write: writes.recorder("b"))
  pacer.report(isFinal: false, write: writes.recorder("c"))
  #expect(writes.log.isEmpty)
  await writes.wait { !writes.log.isEmpty }
  try? await Task.sleep(for: .milliseconds(60))
  #expect(writes.log == ["c:intermediate"])
}

@MainActor
@Test("A drag left without a release is finalised after the quiet spell")
func abandonedDragIsFinalised() async {
  let writes = Writes()
  var pacer = DragWritePacer(debounce: .milliseconds(10), settle: .milliseconds(50))
  pacer.report(isFinal: false, write: writes.recorder("a"))
  await writes.wait { writes.log.count == 2 }
  #expect(writes.log == ["a:intermediate", "a:final"])
}

@MainActor
@Test("A release cancels the pending finalisation: exactly one final lands")
func releaseSupersedesTheSettle() async {
  let writes = Writes()
  // The quiet spell is wide so the release reliably lands inside it, however late
  // the test wakes after the intermediate.
  var pacer = DragWritePacer(debounce: .milliseconds(10), settle: .milliseconds(300))
  pacer.report(isFinal: false, write: writes.recorder("a"))
  await writes.wait { !writes.log.isEmpty }
  pacer.report(isFinal: true, write: writes.recorder("b"))
  try? await Task.sleep(for: .milliseconds(400))
  #expect(writes.log == ["a:intermediate", "b:final"])
}

@MainActor
@Test("Cancelling drops a pending intermediate and its finalisation")
func cancelDropsEverythingPending() async {
  let writes = Writes()
  var pacer = DragWritePacer(debounce: .milliseconds(10), settle: .milliseconds(30))
  pacer.report(isFinal: false, write: writes.recorder("a"))
  pacer.cancel()
  try? await Task.sleep(for: .milliseconds(120))
  #expect(writes.log.isEmpty)
}

@Test("The quiet spell is far longer than the debounce")
func settleOutlastsTheDebounce() {
  // A pointer merely pausing mid-gesture must not read as a release.
  #expect(DragWritePacer.defaultSettle > DragWritePacer.defaultDebounce * 10)
}
