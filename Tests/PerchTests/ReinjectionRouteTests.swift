import Testing

@testable import Perch

// The headphone tap re-injection scripts the player whose track the notch shows —
// playing or paused, since the pause/resume pair must land on the same player — and
// falls back to the system media key only when no scriptable player has a track at all
// (a browser video, a game).

private func track(isPlaying: Bool) -> PanelModel.NowPlaying {
  PanelModel.NowPlaying(title: "T", artist: "A", isPlaying: isPlaying, artworkURL: nil)
}

@MainActor
@Test("A playing scriptable player keeps the ScriptingBridge path")
func playingStaysOnScriptingBridge() {
  #expect(AppModel.reinjectionUsesSystemKey(nowPlaying: track(isPlaying: true)) == false)
}

@MainActor
@Test("A paused player also stays on ScriptingBridge — that is the resume path")
func pausedStaysOnScriptingBridge() {
  // Routing a paused player to the system key broke resume: the injected key is
  // silently dropped without Accessibility trust, so pause worked and resume did not.
  #expect(AppModel.reinjectionUsesSystemKey(nowPlaying: track(isPlaying: false)) == false)
}

@MainActor
@Test("No scriptable track at all falls back to the system media key")
func noTrackFallsBackToSystemKey() {
  #expect(AppModel.reinjectionUsesSystemKey(nowPlaying: nil) == true)
}
