/// What one look at the window list concluded about the notch screen, and on what
/// evidence.
///
/// The reason travels with the verdict because the verdict is circumstantial: no API
/// says "this screen is in full screen", and the windows that betray it differ between
/// macOS releases. When the notch steps aside unexpectedly, the log has to say which
/// evidence it acted on.
struct FullScreenReading: Equatable, Sendable {
  enum Reason: String, Equatable, Sendable {
    /// There is no notch screen to watch, or the window list could not be read.
    case nothingToRead
    /// No other app's window reaches the top band, so nothing can have taken it.
    case nothingAtTheTop
    /// Through macOS 26: the menu bar is listed together with its status items, so it is
    /// showing.
    case menuBarWithStatusItems
    /// Through macOS 26: the menu bar's window is listed without its status items — the
    /// shape of a full-screen space, where that window lingers while the bar hides.
    case menuBarWithoutStatusItems
    /// From macOS 27: the menu bar is listed over the desktop, which no full-screen space
    /// shows.
    case menuBarOverTheDesktop
    /// From macOS 27: the menu bar's window is listed with no desktop under it — again
    /// the shape of a full-screen space.
    case menuBarWithoutDesktop
    /// A window reaches the top band and the menu bar's window is gone with it.
    case menuBarGone
  }

  let reason: Reason

  var isTaken: Bool {
    switch reason {
    case .menuBarWithoutStatusItems, .menuBarWithoutDesktop, .menuBarGone:
      true
    case .nothingToRead, .nothingAtTheTop, .menuBarWithStatusItems, .menuBarOverTheDesktop:
      false
    }
  }
}
