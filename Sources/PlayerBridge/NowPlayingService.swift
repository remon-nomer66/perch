import AppKit
import ScriptingBridge
import ScriptingBridgeGlue

/// Reads what a supported player is playing and drives its transport, through
/// ScriptingBridge rather than the private now-playing API, which returns nothing to a
/// self-signed build.
///
/// A player is only queried while it is already running, so opening the panel never
/// launches Music or Spotify. The playing source wins over a paused one; a stopped
/// player reports nothing.
///
/// Every ScriptingBridge call is a synchronous Apple Event, only as fast as the player
/// answering it, so they all go through an `AppleEventQueue` rather than the main
/// thread: a beachballing player costs one query its deadline, never the UI. The
/// proxies are created and dropped inside each queued item — none crosses a thread.
public final class NowPlayingService: Sendable {
  public struct Info: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let progress: Double
    public let isPlaying: Bool
    /// A remote artwork URL when the player exposes one (Spotify does; Music does not).
    public let artworkURL: String?

    public init(
      title: String?,
      artist: String?,
      progress: Double,
      isPlaying: Bool,
      artworkURL: String?
    ) {
      self.title = title
      self.artist = artist
      self.progress = progress
      self.isPlaying = isPlaying
      self.artworkURL = artworkURL
    }
  }

  /// Spotify reports track duration in milliseconds; Music in seconds. Everything else
  /// about the two scripting interfaces lines up, so one protocol serves both.
  private struct Source {
    let bundleID: String
    let durationInMilliseconds: Bool
  }

  private let sources = [
    Source(bundleID: "com.spotify.client", durationInMilliseconds: true),
    Source(bundleID: "com.apple.Music", durationInMilliseconds: false),
  ]

  private let queue = AppleEventQueue(label: "PlayerBridge.NowPlayingService")
  /// One gate per periodic caller: the panel's refresh and the rule loop's playing
  /// check run on their own cadences and must only skip for their own stuck rounds.
  private let readGate = AppleEventQueue.Gate()
  private let playingGate = AppleEventQueue.Gate()
  /// Hears each proxy's Apple Event failures; kept for the service's lifetime because
  /// `SBApplication.delegate` does not retain. Nil when no denial callback was asked
  /// for, leaving ScriptingBridge's default (return nil, carry on) untouched.
  private let failureDelegate: EventFailureDelegate?

  /// `onAutomationDenied` fires — on the Apple Events queue — when a player refuses
  /// with `errAEEventNotPermitted`: automation for it was switched off in System
  /// Settings, which otherwise just looks like a player with nothing playing.
  public init(onAutomationDenied: (@Sendable () -> Void)? = nil) {
    failureDelegate = onAutomationDenied.map(EventFailureDelegate.init)
  }

  /// Nil when nothing is playing or paused — and when the answer cannot be had in
  /// time, so a hung player empties the now-playing block rather than freezing it.
  public func read() async -> Info? {
    let sources = self.sources
    let delegate = self.failureDelegate
    return await queue.perform(gate: readGate, fallback: nil) { Self.read(sources, delegate) }
  }

  /// The bundle identifier of the player currently playing, nil while none is. This
  /// is what decides whose automation rule holds: the playing player is what the
  /// ears are on, whatever else is open.
  public func playingBundleID() async -> String? {
    let sources = self.sources
    let delegate = self.failureDelegate
    return await queue.perform(gate: playingGate, fallback: nil) {
      Self.playingBundleID(sources, delegate)
    }
  }

  public func playPause() { post { $0.playpause?() } }
  public func next() { post { $0.nextTrack?() } }
  public func previous() { post { $0.previousTrack?() } }

  /// Sends one transport command to the active player, from the queue like every
  /// other Apple Event here.
  private func post(_ command: @escaping @Sendable (SpotifyPlayer) -> Void) {
    let sources = self.sources
    let delegate = self.failureDelegate
    queue.post {
      guard let player = Self.activePlayer(sources, delegate) else { return }
      command(player)
    }
  }

  // MARK: - On the queue

  private static func read(_ sources: [Source], _ delegate: EventFailureDelegate?) -> Info? {
    var pausedFallback: Info?
    for source in sources {
      guard let player = runningPlayer(source.bundleID, delegate),
        let state = player.playerState
      else {
        continue
      }
      if state == .stopped { continue }

      let track = player.currentTrack
      let rawDuration = Double(track?.duration ?? 0)
      let durationSeconds = source.durationInMilliseconds ? rawDuration / 1000 : rawDuration
      let position = player.playerPosition ?? 0
      let progress = durationSeconds > 0 ? min(max(position / durationSeconds, 0), 1) : 0
      let info = Info(
        title: track?.name,
        artist: track?.artist,
        progress: progress,
        isPlaying: state == .playing,
        artworkURL: track?.artworkUrl
      )
      if state == .playing { return info }
      if pausedFallback == nil { pausedFallback = info }
    }
    return pausedFallback
  }

  private static func playingBundleID(
    _ sources: [Source], _ delegate: EventFailureDelegate?
  ) -> String? {
    for source in sources {
      if let player = runningPlayer(source.bundleID, delegate),
        player.playerState == .playing
      {
        return source.bundleID
      }
    }
    return nil
  }

  /// The player a transport command should reach: the playing one, else a paused one
  /// — its track is what the panel shows, so the buttons resuming it match what is
  /// on screen. A player that is merely open with nothing loaded is never sent a
  /// command: while something else (a browser, say) is what is actually heard,
  /// "play" arriving at a stopped player would start a track nobody chose. With no
  /// playing or paused player the command is dropped.
  private static func activePlayer(
    _ sources: [Source], _ delegate: EventFailureDelegate?
  ) -> SpotifyPlayer? {
    var pausedFallback: SpotifyPlayer?
    for source in sources {
      guard let player = runningPlayer(source.bundleID, delegate),
        let state = player.playerState
      else { continue }
      if state == .playing { return player }
      if state == .paused, pausedFallback == nil { pausedFallback = player }
    }
    return pausedFallback
  }

  private static func runningPlayer(
    _ bundleID: String, _ delegate: EventFailureDelegate?
  ) -> SpotifyPlayer? {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
      return nil
    }
    let application = SBApplication(bundleIdentifier: bundleID)
    application?.delegate = delegate
    return application
  }
}

/// Watches each proxy's Apple Event failures for the permission refusal. Everything
/// else keeps ScriptingBridge's default handling: returning nil makes the failed call
/// answer nil, exactly as it does with no delegate set.
///
/// Called on the Apple Events queue; the stored closure is the only state and is
/// immutable, hence the unchecked marker.
private final class EventFailureDelegate: NSObject, SBApplicationDelegate, @unchecked Sendable {
  /// The Apple Events denial, `errAEEventNotPermitted`.
  private static let eventNotPermitted = -1743

  private let onDenied: @Sendable () -> Void

  init(onDenied: @escaping @Sendable () -> Void) {
    self.onDenied = onDenied
  }

  func eventDidFail(
    _ event: UnsafePointer<AppleEvent>, withError error: any Error
  ) -> Any? {
    if (error as NSError).code == Self.eventNotPermitted { onDenied() }
    return nil
  }
}
