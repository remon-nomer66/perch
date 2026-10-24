import Foundation

extension SessionCoordinator {
  public struct Timeouts: Sendable {
    public var response: Duration
    public var grace: Duration
    public var backoffUnit: Duration
    /// How long one write may take to reach the channel. A write is normally done in
    /// milliseconds; one held this long means the remote has stopped granting flow
    /// control, and waiting on it would stall every write queued behind it.
    public var write: Duration
    /// Overrides the dialect-derived readings poll interval. Internal and test-only:
    /// production always derives the cadence from the dialect, so nothing here can
    /// bake in a model-specific value.
    var readingIntervalOverride: Duration?

    // An acknowledgement timeout used to live here, but nothing ever armed it: the
    // response timeout is the one deadline a request needs, and a reply arriving
    // without its acknowledgement is recorded on the request rather than timed.
    public init(
      response: Duration = .seconds(5),
      grace: Duration = .seconds(60),
      // Half a second before the first retry: a headset that drops its channel on a
      // wearing change is back about a second later, which should feel immediate.
      // Doubling still spaces persistent failures out to sixteen seconds.
      backoffUnit: Duration = .milliseconds(500),
      write: Duration = .seconds(5)
    ) {
      self.response = response
      self.grace = grace
      self.backoffUnit = backoffUnit
      self.write = write
    }
  }
}
