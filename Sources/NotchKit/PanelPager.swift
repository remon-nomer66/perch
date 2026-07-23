import CoreGraphics

/// Turns wheel and trackpad scrolling into one page change per gesture.
///
/// The direction is decided by the caller, which feeds either the horizontal or the
/// vertical delta; the accumulator itself is axis-neutral. The panel pages horizontally,
/// so it is given the horizontal delta.
///
/// Trackpads keep sending events after the fingers lift. Feeding that momentum straight
/// into a pager skips three or four pages from a single flick, so the momentum phase is
/// ignored outright and a gesture is latched once it has moved.
public struct PanelPager: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case began
    case changed
    case ended
    /// A mouse wheel, which reports no phase at all.
    case none
  }

  public struct Event: Equatable, Sendable {
    public let delta: CGFloat
    public let phase: Phase
    public let isMomentum: Bool

    public init(delta: CGFloat, phase: Phase = .none, isMomentum: Bool = false) {
      self.delta = delta
      self.phase = phase
      self.isMomentum = isMomentum
    }
  }

  public enum Outcome: Equatable, Sendable {
    case none
    case moved(to: Int)
    /// At the first or last page. The interface answers with a small bounce so the
    /// gesture does not feel ignored.
    case resisted
  }

  public private(set) var index: Int
  public private(set) var pageCount: Int
  public let threshold: CGFloat

  private var accumulated: CGFloat = 0
  /// Set once a gesture has produced a page change, cleared when it ends. A long
  /// single swipe should move one page, not one per threshold crossing.
  private var isLatched = false

  public init(pageCount: Int, index: Int = 0, threshold: CGFloat = 30) {
    self.pageCount = max(1, pageCount)
    self.index = min(max(0, index), max(0, pageCount - 1))
    self.threshold = threshold
  }

  public mutating func setPageCount(_ count: Int) {
    pageCount = max(1, count)
    index = min(index, pageCount - 1)
  }

  public mutating func select(_ page: Int) {
    index = min(max(0, page), pageCount - 1)
  }

  @discardableResult
  public mutating func handle(_ event: Event) -> Outcome {
    if event.phase == .ended {
      isLatched = false
      accumulated = 0
      return .none
    }
    // Momentum is the tail of a gesture that has already been answered.
    guard !event.isMomentum else { return .none }
    if event.phase == .began {
      isLatched = false
      accumulated = 0
    }
    guard !isLatched else { return .none }

    accumulated += event.delta
    guard abs(accumulated) >= threshold else { return .none }

    // A trackpad reports a natural-scrolling delta: pushing content left, which reveals
    // the page to the right, arrives as a negative value.
    let step = accumulated < 0 ? 1 : -1
    accumulated = 0
    if event.phase != .none {
      isLatched = true
    }

    let target = index + step
    guard target >= 0, target < pageCount else { return .resisted }
    index = target
    return .moved(to: index)
  }
}
