/// Decides whether the notch is closed, hinting, or open.
///
/// Pointer movement only ever moves between `closed` and `popping`. Once the panel is
/// `opened` it stays open until it is dismissed by a click. Letting the pointer close
/// it means the panel exists only while the cursor is held still on it, which makes
/// every control inside unreachable.
///
/// There are no timers. Anything that opens or closes on a deadline behaves
/// differently depending on how fast the pointer happened to be moving.
public struct NotchPresenter: Equatable, Sendable {
  public enum Presentation: Equatable, Sendable {
    case closed
    /// The pointer is over the notch. A hint that it can be opened, nothing more.
    case popping
    case opened
  }

  public enum Event: Equatable, Sendable {
    case pointerMoved(isOverNotch: Bool)
    case clicked(isOverNotch: Bool, isInsidePanel: Bool)
    /// The screen arrangement changed, or the session went away.
    case dismiss
  }

  public private(set) var presentation: Presentation = .closed

  public init() {}

  public mutating func handle(_ event: Event) {
    switch event {
    case .pointerMoved(let isOverNotch):
      switch presentation {
      case .closed where isOverNotch:
        presentation = .popping
      case .popping where !isOverNotch:
        presentation = .closed
      case .closed, .popping, .opened:
        break
      }

    case .clicked(let isOverNotch, let isInsidePanel):
      switch presentation {
      case .opened:
        // Outside the panel dismisses it. So does clicking the notch again, which is
        // where the pointer already is after opening.
        if !isInsidePanel || isOverNotch { presentation = .closed }
      case .closed, .popping:
        if isOverNotch { presentation = .opened }
      }

    case .dismiss:
      presentation = .closed
    }
  }
}
