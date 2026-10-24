/// How much of a press the notch log keeps.
struct ClickLogPolicy: Equatable, Sendable {
  /// Logged at notice rather than debug, so the press can still be found afterwards with
  /// `log show`: debug messages are not persisted. Only the two presses that tell
  /// whether the catcher is doing its job — one it took, and one over the notch that
  /// reached another process instead — so the persisted log stays small.
  let isNotable: Bool
  /// Only for presses on what the notch draws: the bar, the catcher, the open panel.
  /// The global monitor sees every press on the screen, and where the user clicks in
  /// other apps is none of this log's business.
  let recordsLocation: Bool

  init(
    route: PointerClick.Route,
    landedOnCatcher: Bool,
    isOverNotch: Bool,
    isInsidePanel: Bool,
    presentation: NotchPresenter.Presentation
  ) {
    isNotable = landedOnCatcher || (route == .global && isOverNotch)
    // Closed, the panel's rectangle is just someone else's window below the menu bar.
    let onPanel = isInsidePanel && presentation == .opened
    recordsLocation = landedOnCatcher || isOverNotch || onPanel
  }
}
