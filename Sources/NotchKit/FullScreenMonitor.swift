import AppKit
import os

/// Watches whether the notch screen has been taken over by a full-screen app — the
/// state in which the menu bar hides itself, and a bar hovering over the content
/// would be unwelcome.
///
/// The window list tells (see `FullScreenRule`). Space changes and app switches re-check
/// at once, and again once the slide has settled; a slow poll catches games and players
/// that take the screen without creating a space. A takeover is reported only once a
/// later reading confirms it, a release at once (see `FullScreenHysteresis`).
@MainActor
public final class FullScreenMonitor {
  private static let log = Logger(subsystem: "dev.perch.mac", category: "fullscreen")
  private static let pollInterval: TimeInterval = 2
  /// How soon the list is read again after a space change or a first taken reading. The
  /// space-change notice can arrive while the old space is still sliding out, and the
  /// slow poll would leave the notch over the content for seconds. Just past the
  /// hysteresis' settling time, so this very read can confirm a takeover.
  private static let followUpDelay = FullScreenHysteresis.settleTime + 0.1

  public var onChange: ((Bool) -> Void)?
  public var isFullScreen: Bool { hysteresis.isFullScreen }

  private let read: @MainActor () -> FullScreenReading
  private let now: @MainActor () -> TimeInterval
  private var hysteresis = FullScreenHysteresis()
  /// The reason last read, so the log records each change of evidence once rather than
  /// once per poll.
  private var lastReason: FullScreenReading.Reason?
  private var observers: [any NSObjectProtocol] = []
  private var poller: Timer?
  private var followUp: Timer?

  public convenience init() {
    let reader = NotchScreenReader()
    self.init(read: reader.read, now: { ProcessInfo.processInfo.systemUptime })
  }

  /// Takes the reading and the time from elsewhere, so the timing can be exercised
  /// without a screen.
  init(
    read: @escaping @MainActor () -> FullScreenReading,
    now: @escaping @MainActor () -> TimeInterval
  ) {
    self.read = read
    self.now = now
  }

  /// A read is already scheduled to look again shortly.
  var isFollowUpPending: Bool { followUp != nil }

  public func start() {
    stop()
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            // A notice already queued when watching stopped must not restart it.
            guard let self, self.poller != nil else { return }
            self.evaluate()
            self.scheduleFollowUp()
          }
        }
      )
    }
    let poller = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.evaluate() }
    }
    RunLoop.main.add(poller, forMode: .common)
    self.poller = poller
    evaluate()
  }

  /// Also reports the screen as no longer taken: whoever stops watching is saying
  /// the answer no longer matters, and a stale "full screen" must not stick.
  public func stop() {
    let center = NSWorkspace.shared.notificationCenter
    observers.forEach { center.removeObserver($0) }
    observers = []
    poller?.invalidate()
    poller = nil
    followUp?.invalidate()
    followUp = nil
    let wasFullScreen = isFullScreen
    hysteresis = FullScreenHysteresis()
    lastReason = nil
    guard wasFullScreen else { return }
    Self.log.info("Notch screen released: no longer watched")
    onChange?(false)
  }

  /// Reads the screen once and reports a change. Internal so the timing can be stepped
  /// through reading by reading.
  func evaluate() {
    let reading = read()
    let reason = reading.reason.rawValue
    if reading.reason != lastReason {
      lastReason = reading.reason
      Self.log.debug("Read \(reason, privacy: .public) (taken: \(reading.isTaken))")
    }
    let previous = hysteresis
    hysteresis = previous.applying(reading, at: now())
    if hysteresis.isAwaitingConfirmation { scheduleFollowUp() }
    guard hysteresis.isFullScreen != previous.isFullScreen else { return }
    let state = hysteresis.isFullScreen ? "taken" : "released"
    Self.log.info("Notch screen \(state, privacy: .public): \(reason, privacy: .public)")
    onChange?(hysteresis.isFullScreen)
  }

  /// One read is pending at most; a request while it waits is already covered by it.
  private func scheduleFollowUp() {
    guard followUp == nil else { return }
    let followUp = Timer(timeInterval: Self.followUpDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.followUp = nil
        self?.evaluate()
      }
    }
    RunLoop.main.add(followUp, forMode: .common)
    self.followUp = followUp
  }
}
