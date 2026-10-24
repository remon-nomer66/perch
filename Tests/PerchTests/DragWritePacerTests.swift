import Testing

@testable import Perch

// How one dragged control's reports become device writes: intermediate positions are
// sent once the pointer pauses, the release is sent at once as final — and a drag whose
// release never arrives (the panel closed under the finger) is finalised on its own
// after a quiet spell, rather than leaving the device mid-drag and the field guarded.
// Both waits run on a manual timer: each `fire` is "that wait ran its full length".

/// The writes the pacer asked for, as "<report>:<final|intermediate>".
@MainActor
private final class Writes {
  var log: [String] = []

  func recorder(_ name: String) -> @MainActor (Bool) -> Void {
    { [weak self] isFinal in self?.log.append("\(name):\(isFinal ? "final" : "intermediate")") }
  }
}

@MainActor
@Test("A release is written at once, as final")
func releaseIsWrittenAtOnce() async {
  let writes = Writes()
  let timer = ManualTimer()
  var pacer = DragWritePacer(sleep: timer.sleep)
  pacer.report(isFinal: true, write: writes.recorder("a"))
  #expect(writes.log == ["a:final"])
  await timer.drain()
}

@MainActor
@Test("Reports in quick succession send only the last, once the pointer pauses")
func intermediatesAreDebounced() async {
  let writes = Writes()
  let timer = ManualTimer()
  var pacer = DragWritePacer(sleep: timer.sleep)
  pacer.report(isFinal: false, write: writes.recorder("a"))
  pacer.report(isFinal: false, write: writes.recorder("b"))
  pacer.report(isFinal: false, write: writes.recorder("c"))
  await waitUntil { timer.pending == 3 }
  #expect(writes.log.isEmpty)

  // The pause: every debounce ends, but only the last report's still counts.
  timer.fire()
  await waitUntil { !writes.log.isEmpty }
  await yieldToMainActor()
  #expect(writes.log == ["c:intermediate"])

  pacer.cancel()
  await timer.drain()
}

@MainActor
@Test("A drag left without a release is finalised after the quiet spell")
func abandonedDragIsFinalised() async {
  let writes = Writes()
  let timer = ManualTimer()
  var pacer = DragWritePacer(sleep: timer.sleep)
  pacer.report(isFinal: false, write: writes.recorder("a"))
  await waitUntil { timer.pending == 1 }
  timer.fire()
  await waitUntil { writes.log == ["a:intermediate"] && timer.pending == 1 }
  #expect(writes.log == ["a:intermediate"])

  timer.fire()
  await waitUntil { writes.log.count == 2 }
  #expect(writes.log == ["a:intermediate", "a:final"])
  await timer.drain()
}

@MainActor
@Test("A release cancels the pending finalisation: exactly one final lands")
func releaseSupersedesTheSettle() async {
  let writes = Writes()
  let timer = ManualTimer()
  var pacer = DragWritePacer(sleep: timer.sleep)
  pacer.report(isFinal: false, write: writes.recorder("a"))
  await waitUntil { timer.pending == 1 }
  timer.fire()
  await waitUntil { writes.log == ["a:intermediate"] && timer.pending == 1 }

  pacer.report(isFinal: true, write: writes.recorder("b"))
  #expect(writes.log == ["a:intermediate", "b:final"])
  // The quiet spell the release superseded runs out after all: it must write nothing.
  timer.fire()
  await yieldToMainActor()
  #expect(writes.log == ["a:intermediate", "b:final"])
  await timer.drain()
}

@MainActor
@Test("Cancelling drops a pending intermediate and its finalisation")
func cancelDropsEverythingPending() async {
  let writes = Writes()
  let timer = ManualTimer()
  var pacer = DragWritePacer(sleep: timer.sleep)
  pacer.report(isFinal: false, write: writes.recorder("a"))
  pacer.cancel()
  await waitUntil { timer.pending == 1 }
  timer.fire()
  await yieldToMainActor()
  #expect(writes.log.isEmpty)
  await timer.drain()
}

@Test("The quiet spell is far longer than the debounce")
func settleOutlastsTheDebounce() {
  // A pointer merely pausing mid-gesture must not read as a release.
  #expect(DragWritePacer.defaultSettle > DragWritePacer.defaultDebounce * 10)
}
