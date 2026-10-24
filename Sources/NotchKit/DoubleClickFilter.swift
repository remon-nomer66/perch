/// Keeps the second press of a double click from undoing the first.
///
/// A press that opens the panel puts the panel under the pointer, so the next press of
/// the same double click lands on the notch of an open panel — read as a click there,
/// it shuts what the first press just opened. Not every repeat is that, though: AppKit
/// counts any quick press near the last one, and after a press that changed nothing —
/// a control in the panel, say, then the notch straight after to close it — holding
/// the repeat back would leave a dead click instead.
struct DoubleClickFilter: Equatable, Sendable {
  /// Whether the last press handed on opened or closed the panel.
  private var lastPressActed = false

  /// Hands `event`, the presenter's reading of `click`, on to the presenter unless the
  /// press repeats one that just opened or closed the panel. A press held back leaves
  /// the record as it was, so a triple click is still one click. Returns whether the
  /// event was handed on.
  @discardableResult
  mutating func pass(
    _ event: NotchPresenter.Event,
    of click: PointerClick,
    to presenter: inout NotchPresenter
  ) -> Bool {
    guard !(click.isRepeat && lastPressActed) else { return false }
    let before = presenter.presentation
    presenter.handle(event)
    lastPressActed = presenter.presentation != before
    return true
  }
}
