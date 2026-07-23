import CoreGraphics

/// Where the notch sits on a screen.
///
/// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` describe the *unobstructed*
/// corners, not the notch. The notch is the gap between them, so it is derived from
/// their coordinates. Subtracting widths from the screen width instead would misplace
/// it on a screen whose origin is not zero, or whose two areas are not symmetric.
public struct ScreenNotchGeometry: Equatable, Sendable {
  public let rect: CGRect

  public init(rect: CGRect) {
    self.rect = rect
  }

  /// Returns the notch rectangle, or `nil` when this screen has no usable notch.
  ///
  /// A `nil` is not an error: plenty of displays have no notch, and the application
  /// has to remain reachable on them.
  public static func resolve(
    screenFrame: CGRect,
    safeAreaTop: CGFloat,
    leftArea: CGRect?,
    rightArea: CGRect?
  ) -> ScreenNotchGeometry? {
    guard safeAreaTop > 0, let leftArea, let rightArea else { return nil }

    let x = leftArea.maxX
    let width = rightArea.minX - leftArea.maxX
    guard width > 0 else { return nil }

    let rect = CGRect(
      x: x,
      y: screenFrame.maxY - safeAreaTop,
      width: width,
      height: safeAreaTop
    )
    // A rectangle that escapes the screen means the inputs disagree with each other,
    // and a misplaced rectangle would swallow clicks meant for the menu bar.
    guard screenFrame.contains(rect) else { return nil }
    return ScreenNotchGeometry(rect: rect)
  }
}
