import CoreGraphics

/// Whether the notch screen's desktop has been seen at least once — which is what lets
/// the desktop's absence mean anything.
///
/// From macOS 27, a full-screen space is told from the desktop by the desktop's own
/// windows leaving the list. Where those windows never show — Finder's desktop switched
/// off, or Finder not running — their absence is the ordinary state, and taking it for
/// full screen would hide the notch for good. So the absence counts only once the
/// desktop has been seen on the same screen. A different frame is a different screen,
/// or the same one rearranged, with a desktop of its own still to be seen; the record
/// then starts over rather than vouching for a screen it never looked at.
struct DesktopSighting: Equatable, Sendable {
  /// The frame the record is about; nil before the first reading.
  let screenFrame: CGRect?
  let sawDesktop: Bool

  init() {
    self.init(screenFrame: nil, sawDesktop: false)
  }

  private init(screenFrame: CGRect?, sawDesktop: Bool) {
    self.screenFrame = screenFrame
    self.sawDesktop = sawDesktop
  }

  func hasSeenDesktop(on frame: CGRect) -> Bool {
    screenFrame == frame && sawDesktop
  }

  /// The record after a reading taken on `frame`.
  func noting(_ reading: FullScreenReading, on frame: CGRect) -> DesktopSighting {
    DesktopSighting(
      screenFrame: frame, sawDesktop: hasSeenDesktop(on: frame) || reading.showsDesktop
    )
  }
}
