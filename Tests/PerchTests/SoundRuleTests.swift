import Foundation
import Testing

@testable import Perch

@Test("The pinned players resolve to their titles without touching the workspace")
@MainActor
func knownAppsResolveByTitle() {
  #expect(SoundRule.appTitle(for: "com.spotify.client") == "Spotify")
  let musicTitle = SoundRule.appTitle(for: "com.apple.Music")
  #expect(musicTitle == "ミュージック" || musicTitle == "Music")
}

@Test("An unknown, uninstalled bundle keeps its identifier as a last resort")
@MainActor
func unknownBundleFallsBackToIdentifier() {
  let identifier = "com.example.not-installed-\(UUID().uuidString)"
  #expect(SoundRule.appTitle(for: identifier) == identifier)
}

@Test("A rule round-trips through Codable")
func ruleRoundTripsThroughCodable() throws {
  var rule = SoundRule(trigger: .site("example.com"))
  rule.noise = .ambient
  rule.equalizerPreset = 0xA0
  rule.listening = .standard
  let data = try JSONEncoder().encode(rule)
  let decoded = try JSONDecoder().decode(SoundRule.self, from: data)
  #expect(decoded == rule)
}
