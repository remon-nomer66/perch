import PlayerBridge

/// Why the panel is being refreshed — which decides whether the players are asked.
///
/// The now-playing read goes through a gate that lets one round run at a time and
/// answers "nothing" to a caller that finds it taken. For one cadence that is right: a
/// round stuck on a hung player should empty the readout, not freeze it. But the
/// read-back after every device write refreshed through the same gate on a clock of
/// its own. Landing while the half-second round was in flight, it was handed that
/// "nothing" and published it: the track vanished for a tick, and a headphone tap in
/// that tick went out as a system media key rather than to the player on screen (see
/// `AppModel.reinjectionUsesSystemKey`). A device write changes nothing a player
/// reports, so its refresh keeps the readout it finds — and no longer waits out a hung
/// player's deadline in the middle of the write chain either.
enum PanelRefreshCause {
  /// The half-second loop: the one cadence the now-playing read is gated for.
  case periodic
  /// The read-back after a device write.
  case deviceWrite

  /// The now-playing part of a refresh. `read` — the gated Apple Events round — runs
  /// only for the periodic refresh, and only once player queries are allowed.
  @MainActor
  func nowPlaying(
    queriesAllowed: Bool,
    read: () async -> NowPlayingService.Info?
  ) async -> NowPlayingReadout {
    switch self {
    case .deviceWrite:
      return .unchanged
    case .periodic:
      guard queriesAllowed else { return .read(nil) }
      return .read(await read().map(PanelModel.NowPlaying.init))
    }
  }
}

/// What a refresh learned about the now-playing readout.
enum NowPlayingReadout: Equatable {
  /// The players were asked; nil when nothing is playing or paused, or the answer
  /// could not be had in time.
  case read(PanelModel.NowPlaying?)
  /// The players were not asked: the panel goes on showing what it shows.
  case unchanged

  /// Resolved against the panel as the new model is assembled, not as the refresh
  /// began: a periodic round that published in between is not overwritten.
  func resolved(current: PanelModel.NowPlaying?) -> PanelModel.NowPlaying? {
    switch self {
    case .read(let fresh): fresh
    case .unchanged: current
    }
  }
}

extension PanelModel.NowPlaying {
  init(_ info: NowPlayingService.Info) {
    self.init(
      title: info.title,
      artist: info.artist,
      isPlaying: info.isPlaying,
      artworkURL: info.artworkURL
    )
  }
}
