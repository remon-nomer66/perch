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

@Test("A rule stored before deviceModel existed still decodes, with deviceModel nil")
func legacyJSONDecodesWithNilDeviceModel() throws {
  // The exact on-disk shape a released build wrote: no deviceModel key, the trigger
  // as a single-key object, noise/listening as raw strings, the preset as a number.
  let legacy = #"""
  {"noise":"ambient","equalizerPreset":160,"id":"E88A355F-A7A1-4366-889A-39AC30D7910C","trigger":{"site":{"_0":"example.com"}},"listening":"standard"}
  """#
  let decoded = try JSONDecoder().decode(SoundRule.self, from: Data(legacy.utf8))
  #expect(decoded.trigger == .site("example.com"))
  #expect(decoded.deviceModel == nil)  // absent key ⇒ "all devices" (grandfathered)
  #expect(decoded.noise == .ambient)
  #expect(decoded.equalizerPreset == 0xA0)
  #expect(decoded.listening == .standard)
}

@Test("A new rule defaults to no device scope")
func newRuleDefaultsToNoDeviceScope() {
  #expect(SoundRule(trigger: .app("com.spotify.client")).deviceModel == nil)
}

@Test("An artist rule with a device scope round-trips through Codable")
func artistRuleRoundTrips() throws {
  var rule = SoundRule(trigger: .artist("YOASOBI"))
  rule.deviceModel = "WH-1000XM6"
  rule.noise = .noiseCancelling
  rule.equalizerPreset = 0x01
  rule.listening = .standard
  let data = try JSONEncoder().encode(rule)
  let decoded = try JSONDecoder().decode(SoundRule.self, from: data)
  #expect(decoded == rule)
  #expect(decoded.trigger == .artist("YOASOBI"))
  #expect(decoded.deviceModel == "WH-1000XM6")
}
