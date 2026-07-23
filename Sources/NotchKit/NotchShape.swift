import SwiftUI

/// The panel outline: square across the top where it meets the screen edge, rounded
/// below, with the top corners curving outwards into the menu bar.
///
/// Those outward curves are what make the panel read as the notch growing rather than
/// as a window that happens to sit near it.
public struct NotchShape: Shape {
  public var topCornerRadius: CGFloat
  public var bottomCornerRadius: CGFloat

  public init(topCornerRadius: CGFloat = 10, bottomCornerRadius: CGFloat = 20) {
    self.topCornerRadius = topCornerRadius
    self.bottomCornerRadius = bottomCornerRadius
  }

  public var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
    set {
      topCornerRadius = newValue.first
      bottomCornerRadius = newValue.second
    }
  }

  public func path(in rect: CGRect) -> Path {
    var path = Path()
    let top = min(topCornerRadius, rect.height / 2)
    let bottom = min(bottomCornerRadius, rect.height / 2, rect.width / 2)

    path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
    // Curve outwards so the shape flows into the screen edge instead of butting
    // against it.
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.minY + top),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
      control: CGPoint(x: rect.minX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
      control: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX + top, y: rect.minY),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )
    path.closeSubpath()
    return path
  }
}
