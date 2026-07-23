import CoreGraphics

/// Where the notch sits on a screen.
///
/// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` describe the *unobstructed*
/// corners, not the notch. The notch is the gap between them, so it is derived from
/// their coordinates. Subtracting widths from the screen width instead would misplace
/// it on a screen whose origin is not zero, or whose two areas are not symmetric.
public struct ScreenNotchGeometry: Equatable, Sendable {
  public let rect: CGRect
  /// True when this notch was synthesised on a screen that has no cutout of its own,
  /// so the app's notch interface is reachable there too. A virtual notch rests as a
  /// thin sliver rather than always showing a bar, which is the one behaviour that
  /// separates it from a real one.
  public let isVirtual: Bool

  public init(rect: CGRect, isVirtual: Bool = false) {
    self.rect = rect
    self.isVirtual = isVirtual
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

  /// A notch made up at the top-centre of a screen that has none.
  ///
  /// On a Mac with no cutout the app would otherwise have no notch to live in, so one
  /// is placed over the menu bar: as wide as `width` (nominal — there is no real notch
  /// to measure), as tall as the menu bar it overlays. The caller supplies the menu
  /// bar height because a screen with no notch reports no safe-area inset to read it
  /// from. Returns `nil` when the inputs cannot make a rectangle that fits the screen.
  public static func synthesized(
    screenFrame: CGRect,
    menuBarHeight: CGFloat,
    width: CGFloat
  ) -> ScreenNotchGeometry? {
    guard menuBarHeight > 0, width > 0, width <= screenFrame.width else { return nil }

    let rect = CGRect(
      x: screenFrame.midX - width / 2,
      y: screenFrame.maxY - menuBarHeight,
      width: width,
      height: menuBarHeight
    )
    guard screenFrame.contains(rect) else { return nil }
    return ScreenNotchGeometry(rect: rect, isVirtual: true)
  }
}
