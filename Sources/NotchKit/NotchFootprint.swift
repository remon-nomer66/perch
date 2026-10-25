import CoreGraphics

extension NotchAppearance {
  /// The rectangle the notch occupies while the panel is not open, in screen
  /// coordinates: what the hosted view draws, and therefore what the pointer must reach.
  ///
  /// Drawing and hit testing both read this one answer. Worked out separately they
  /// drifted: the view centred the widened bar on the cutout while the hit test honoured
  /// the left and right reaches as set, so a strip of the drawn bar ignored the pointer
  /// and an undrawn strip on the other side answered it.
  ///
  /// `isBarExtended` is the host's call on whether the bar is widened just now. The
  /// resting sliver is only for a virtual notch that is closed and not widened: looked
  /// at, it is drawn at the whole cutout, and a target left at the sliver would close it
  /// again as soon as the pointer moved down into what is drawn.
  public func barRect(
    around notch: CGRect,
    isVirtual: Bool,
    isBarExtended: Bool,
    presentation: NotchPresenter.Presentation
  ) -> CGRect {
    if isBarExtended { return closedRect(around: notch) }
    if isVirtual && presentation == .closed { return restingSliver(in: notch) }
    return notch
  }
}
