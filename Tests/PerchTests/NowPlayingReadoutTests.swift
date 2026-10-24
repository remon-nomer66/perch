import PlayerBridge
import Testing

@testable import Perch

// Only the periodic refresh asks the players. The now-playing read is gated for one
// cadence: a second caller finding the gate taken is answered "nothing", and a write's
// read-back that published that answer emptied the track for a tick — long enough for
// a headphone tap to go out as a system media key instead of to the player on screen.

/// Counts how often the players were asked, and answers with a fixed reply.
@MainActor
private final class Players {
  var asked = 0
  let answer: NowPlayingService.Info?

  init(answer: NowPlayingService.Info?) {
    self.answer = answer
  }

  func read() async -> NowPlayingService.Info? {
    asked += 1
    return answer
  }
}

private let playing = NowPlayingService.Info(
  title: "T", artist: "A", progress: 0.5, isPlaying: true, artworkURL: "https://example.invalid/a"
)

private let shown = PanelModel.NowPlaying(title: "S", artist: "B", isPlaying: false, artworkURL: nil)

@MainActor
@Test("A device write's refresh never asks the players and keeps the track shown")
func deviceWriteKeepsTheReadout() async {
  let players = Players(answer: nil)
  let readout = await PanelRefreshCause.deviceWrite.nowPlaying(queriesAllowed: true) {
    await players.read()
  }
  #expect(players.asked == 0)
  #expect(readout == .unchanged)
  #expect(readout.resolved(current: shown) == shown)
}

@MainActor
@Test("The periodic refresh asks the players and shows what they answer")
func periodicRereadsThePlayers() async {
  let players = Players(answer: playing)
  let readout = await PanelRefreshCause.periodic.nowPlaying(queriesAllowed: true) {
    await players.read()
  }
  #expect(players.asked == 1)
  let expected = PanelModel.NowPlaying(
    title: "T", artist: "A", isPlaying: true, artworkURL: "https://example.invalid/a"
  )
  #expect(readout.resolved(current: shown) == expected)
}

@MainActor
@Test("A periodic answer of nothing empties the readout — a hung player must not freeze it")
func periodicNothingEmptiesTheReadout() async {
  let players = Players(answer: nil)
  let readout = await PanelRefreshCause.periodic.nowPlaying(queriesAllowed: true) {
    await players.read()
  }
  #expect(players.asked == 1)
  #expect(readout.resolved(current: shown) == nil)
}

@MainActor
@Test("Before the launch-time permission gate lifts, nothing is asked and nothing shown")
func periodicWaitsForThePermissionGate() async {
  let players = Players(answer: playing)
  let readout = await PanelRefreshCause.periodic.nowPlaying(queriesAllowed: false) {
    await players.read()
  }
  #expect(players.asked == 0)
  #expect(readout.resolved(current: shown) == nil)
}
