import CoreGraphics

/// Where the notch answers the pointer. Pure geometry, kept apart from the controller
/// so it is checked without a window server.
extension NotchController {
  /// A little slack around what is drawn: demanding pixel accuracy makes the target
  /// feel smaller than it looks.
  nonisolated static let hitSlack: CGFloat = 4

  /// What the pointer must reach to count as "over the notch", in global screen
  /// coordinates, before slack: exactly the rectangle the view draws in this state.
  /// `barVisible` is the host's answer to whether the bar is widened just now.
  nonisolated static func hoverTarget(
    barVisible: Bool,
    presentation: NotchPresenter.Presentation,
    notch: CGRect,
    isVirtual: Bool,
    appearance: NotchAppearance
  ) -> CGRect {
    appearance.barRect(
      around: notch, isVirtual: isVirtual, isBarExtended: barVisible, presentation: presentation
    )
  }

  /// The hover target with its slack, the region pointer locations are tested against.
  /// Deliberately not clipped to the screen: the slack above the top edge is what keeps
  /// a pointer pressed against that edge inside.
  nonisolated static func notchTarget(
    barVisible: Bool,
    presentation: NotchPresenter.Presentation,
    notch: CGRect,
    isVirtual: Bool,
    appearance: NotchAppearance
  ) -> CGRect {
    hoverTarget(
      barVisible: barVisible, presentation: presentation, notch: notch, isVirtual: isVirtual,
      appearance: appearance
    )
    .insetBy(dx: -hitSlack, dy: -hitSlack)
  }
}
