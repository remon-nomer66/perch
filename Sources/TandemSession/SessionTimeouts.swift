import Foundation

extension SessionCoordinator {
  public struct Timeouts: Sendable {
    public var response: Duration
    public var grace: Duration
    public var backoffUnit: Duration
    /// How long one write may take to reach the channel. A write is normally done in
    /// milliseconds; one held this long means the remote has stopped granting flow
    /// control, and waiting on it would stall every write queued behind it. Kept
    /// shorter than `response`, whose deadline covers the write as well, so that a
    /// stalled write is reported as a stall rather than racing its own request's
    /// timeout.
    public var write: Duration
    /// How long `contended` waits before trying the channel again. Slow on purpose:
    /// while another host really holds the channel, every try hangs for the whole
    /// open timeout.
    public var contentionRetry: Duration
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
      write: Duration = .seconds(3),
      contentionRetry: Duration = .seconds(30)
    ) {
      self.response = response
      self.grace = grace
      self.backoffUnit = backoffUnit
      self.write = write
      self.contentionRetry = contentionRetry
    }
  }
}
