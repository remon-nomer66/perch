import ScriptingBridge
import ScriptingBridgeGlue
import Testing

@testable import PlayerBridge

/// Confirms the ScriptingBridge interfaces link and reach Swift through SwiftPM.
/// Nothing here sends an Apple Event, so it needs no permission and no running player.
@Test func spotifyInterfaceLinksAndConforms() {
  #expect(SBApplication.conforms(to: SpotifyPlayer.self))
}

@Test func playerStateConstantsMatchScriptingDefinition() {
  #expect(SpotifyPlayerStateValue.playing.rawValue == 0x6B50_5350)
  #expect(SpotifyPlayerStateValue.paused.rawValue == 0x6B50_5370)
  #expect(SpotifyPlayerStateValue.stopped.rawValue == 0x6B50_5353)
}
