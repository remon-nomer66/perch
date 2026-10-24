import CoreGraphics

/// The frame last asked of a window, and the frame it settled on.
///
/// AppKit rounds a window's frame to whole points: asked for (721.63, 1127.37, 356.41,
/// 41.5), a window settles on (721, 1127, 357, 42). Comparing a request against `frame`
/// therefore finds a difference every time, and the notch's windows were moved again on
/// every pointer event and poll tick. A request is compared with the last request
/// instead — and the window with where it settled, so one moved by anyone else is put
/// back all the same.
struct FrameRequest: Equatable, Sendable {
  private var asked: CGRect?
  private var settled: CGRect?

  /// Whether `frame` has to be set on a window whose frame is now `current`.
  func needsPlacing(_ frame: CGRect, current: CGRect) -> Bool {
    frame != asked || current != settled
  }

  mutating func record(asked: CGRect, settled: CGRect) {
    self.asked = asked
    self.settled = settled
  }
}
