import CoreGraphics

/// Where the notch answers the pointer, and what a press on it means. Pure geometry and
/// decisions, kept apart from the controller so each is checked without a window server.
extension NotchController {
  /// A little slack around what is drawn: demanding pixel accuracy makes the target
  /// feel smaller than it looks.
  nonisolated static let hitSlack: CGFloat = 4

  /// Added above the open panel. Its top edge is the screen's, and `NSEvent.mouseLocation`
  /// reports a pointer pressed against that edge as exactly the screen's maxY — which
  /// `CGRect.contains` counts as outside, so a press on the panel's top row dismissed it.
  nonisolated static let panelTopSlack: CGFloat = 1

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

  /// The open panel, centred on the cutout and hanging from the screen's top edge.
  nonisolated static func panelTarget(
    notch: CGRect, screenFrame: CGRect, appearance: NotchAppearance
  ) -> CGRect {
    let size = appearance.expandedSize
    return CGRect(
      x: notch.midX - size.width / 2,
      y: screenFrame.maxY - size.height,
      width: size.width,
      height: size.height + panelTopSlack
    )
  }

  /// The frame the click catcher takes, or nil when it should stand aside.
  ///
  /// It covers the notch target while the panel is closed or hinting, and nothing more:
  /// the window server routes a press by window frame, so one just past the bar's edge
  /// reaches the menu bar whatever the pointer polling has caught up on. Clipped to the
  /// notch screen, where the target's slack past the top edge would otherwise swallow
  /// presses along the bottom of a display arranged above. Nil while open, when the
  /// strip itself takes the presses and a catcher would only stand between the pointer
  /// and the panel.
  nonisolated static func catcherFrame(
    presentation: NotchPresenter.Presentation, notchTarget: CGRect, screenFrame: CGRect
  ) -> CGRect? {
    guard presentation != .opened else { return nil }
    let frame = notchTarget.intersection(screenFrame)
    return frame.isNull || frame.isEmpty ? nil : frame
  }

  /// What a press tells the presenter.
  ///
  /// A press the catcher received is on the notch whatever the geometry now says: the
  /// window server already found the pointer on the bar and kept the press from the
  /// menu bar, and doing nothing with a press nobody else got is the dead click the
  /// catcher exists to end. Not while open, though: the catcher stands aside then, and
  /// a press still routed to it was queued before it did — the geometry decides that one.
  nonisolated static func presenterEvent(
    for click: PointerClick,
    presentation: NotchPresenter.Presentation,
    catcherWindowNumber: Int?,
    isOverNotch: Bool,
    isInsidePanel: Bool
  ) -> NotchPresenter.Event {
    let onCatcher = presentation != .opened && click.landed(onWindow: catcherWindowNumber)
    return .clicked(isOverNotch: onCatcher || isOverNotch, isInsidePanel: isInsidePanel)
  }
}
