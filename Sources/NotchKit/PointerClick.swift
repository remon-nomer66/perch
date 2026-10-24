import CoreGraphics

/// One press of a mouse button, as the pointer monitor saw it.
public struct PointerClick: Equatable, Sendable {
  /// Which monitor reported the press. One aimed at another process's window — the
  /// menu bar's included — reaches only the global monitor, and one aimed at a window
  /// of ours only the local one, so every press arrives by exactly one of the two.
  public enum Route: String, Equatable, Sendable {
    case global
    case local
  }

  /// In global screen coordinates, the same space the notch geometry is kept in.
  public let location: CGPoint
  public let route: Route
  /// AppKit's count of presses in quick succession at one spot: 2 for the second press
  /// of a double click.
  public let clickCount: Int
  /// The window the press was aimed at, by number. Kept only on the local route: a
  /// global press names another process's window, and nothing of ours compares to it.
  public let windowNumber: Int?

  public init(location: CGPoint, route: Route, clickCount: Int, windowNumber: Int?) {
    self.location = location
    self.route = route
    self.clickCount = clickCount
    self.windowNumber = route == .local ? windowNumber : nil
  }

  /// The second or later press of a double click; see `DoubleClickFilter` for when
  /// that matters.
  public var isRepeat: Bool { clickCount > 1 }

  /// Whether the press was delivered to the given window of ours. Two unknowns are not
  /// a match: with no such window up, a press aimed at no window is not on it.
  public func landed(onWindow number: Int?) -> Bool {
    guard let number, let windowNumber else { return false }
    return windowNumber == number
  }
}
