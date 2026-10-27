import CoreGraphics
import Testing

@testable import NotchKit

/// A request AppKit does not keep as asked: it settles a window's frame on whole points.
private let asked = CGRect(x: 721.63, y: 1127.37, width: 356.41, height: 41.5)
private let settled = CGRect(x: 721, y: 1127, width: 357, height: 42)

@Test func aWindowNeverPlacedNeedsPlacing() {
  #expect(FrameRequest().needsPlacing(asked, current: .zero))
}

@Test func theSameRequestAgainIsNotAChangeThoughTheFrameWasRounded() {
  // Compared with `frame`, the rounded result differs from every request, and the
  // window was moved again on every pointer event and poll tick.
  var request = FrameRequest()
  request.record(asked: asked, settled: settled)

  #expect(!request.needsPlacing(asked, current: settled))
}

@Test func aDifferentRequestIsAChange() {
  var request = FrameRequest()
  request.record(asked: asked, settled: settled)

  #expect(request.needsPlacing(asked.offsetBy(dx: 10, dy: 0), current: settled))
}

@Test func aWindowMovedByAnyoneElseIsPlacedAgain() {
  // A display going away can have the system move the window; the same request then
  // still has to put it back where it was asked to be.
  var request = FrameRequest()
  request.record(asked: asked, settled: settled)

  #expect(request.needsPlacing(asked, current: settled.offsetBy(dx: 0, dy: -300)))
}
