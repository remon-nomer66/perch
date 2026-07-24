import Testing

@testable import Perch

// The headphone tap re-injection keeps the proven ScriptingBridge path only while a
// scriptable player is actually playing; every other state falls back to the system
// media key, which reaches a browser or any other player.

@MainActor
@Test("A playing scriptable player keeps the ScriptingBridge path")
func playingStaysOnScriptingBridge() {
  #expect(AppModel.reinjectionUsesSystemKey(isPlaying: true) == false)
}

@MainActor
@Test("A paused player falls back to the system media key")
func pausedFallsBackToSystemKey() {
  #expect(AppModel.reinjectionUsesSystemKey(isPlaying: false) == true)
}

@MainActor
@Test("No scriptable player at all falls back to the system media key")
func noPlayerFallsBackToSystemKey() {
  #expect(AppModel.reinjectionUsesSystemKey(isPlaying: nil) == true)
}
