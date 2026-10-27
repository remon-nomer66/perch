import Foundation

/// Holds a switch to full screen back until the window list has said so on two looks a
/// moment apart, and lets the screen go again on the first reading that says otherwise.
///
/// While a space slides in or out, the window list passes through shapes no settled
/// screen has — the desktop half off the screen, two menu bars side by side — and a
/// single reading taken mid-slide can be wrong. Stepping the notch aside on one reading
/// would make it blink through every transition. Counting readings alone is not enough
/// either: a space change and the app switch it causes arrive together and read the
/// same instant twice, so the second look has to come a settling time after the first.
/// Coming back is immediate on purpose: a notch hidden by mistake is the worse failure,
/// since there is then no way to reach it.
struct FullScreenHysteresis: Equatable, Sendable {
  /// How long taken readings must keep coming, uninterrupted, before the screen counts
  /// as taken: far longer than the gap between the notifications of one transition,
  /// and short enough to go unnoticed next to the slide itself.
  static let settleTime: TimeInterval = 0.4

  let isFullScreen: Bool
  /// When the current run of taken readings began; nil once a reading says otherwise.
  let takenSince: TimeInterval?

  init() {
    self.init(isFullScreen: false, takenSince: nil)
  }

  private init(isFullScreen: Bool, takenSince: TimeInterval?) {
    self.isFullScreen = isFullScreen
    self.takenSince = takenSince
  }

  /// A taken reading is waiting for the one that confirms it. Worth reading again soon
  /// rather than at the next slow poll, so the notch steps aside about when the menu
  /// bar does.
  var isAwaitingConfirmation: Bool { !isFullScreen && takenSince != nil }

  /// `time` only needs to be monotonic; it is compared, never shown.
  func applying(_ reading: FullScreenReading, at time: TimeInterval) -> FullScreenHysteresis {
    guard reading.isTaken else { return FullScreenHysteresis() }
    guard !isFullScreen else { return self }
    guard let since = takenSince else {
      return FullScreenHysteresis(isFullScreen: false, takenSince: time)
    }
    return FullScreenHysteresis(isFullScreen: time - since >= Self.settleTime, takenSince: since)
  }
}
