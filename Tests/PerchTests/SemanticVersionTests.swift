import Testing

@testable import Perch

@Test("A plain and a v-prefixed tag parse to the same version")
func parsesPrefixAndPlain() {
  #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
  #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
  #expect(SemanticVersion("V1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
}

@Test("Missing components read as zero")
func fillsMissingComponents() {
  #expect(SemanticVersion("1") == SemanticVersion(major: 1, minor: 0, patch: 0))
  #expect(SemanticVersion("1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
}

@Test("Pre-release and build metadata after the core are tolerated")
func parsesSuffixes() {
  #expect(SemanticVersion("1.2.3+build.9")?.patch == 3)
  let beta = SemanticVersion("1.2.3-beta.1")
  #expect(beta?.patch == 3)
  #expect(beta?.isPreRelease == true)
  #expect(SemanticVersion("1.2.3")?.isPreRelease == false)
}

@Test("Non-versions do not parse")
func rejectsNonVersions() {
  #expect(SemanticVersion("") == nil)
  #expect(SemanticVersion("開発ビルド") == nil)
  #expect(SemanticVersion("v") == nil)
  // A present-but-unparseable component fails rather than reading as zero.
  #expect(SemanticVersion("1.x") == nil)
}

@Test("Ordering compares major, then minor, then patch")
func ordersByComponent() {
  #expect(SemanticVersion("1.0.0")! < SemanticVersion("2.0.0")!)
  #expect(SemanticVersion("1.1.0")! < SemanticVersion("1.2.0")!)
  #expect(SemanticVersion("1.0.1")! < SemanticVersion("1.0.2")!)
  #expect(SemanticVersion("1.2.0")! > SemanticVersion("1.1.9")!)
  #expect(SemanticVersion("1.0.0")! == SemanticVersion("1.0.0")!)
}

@Test("A pre-release precedes the final release of the same core")
func preReleasePrecedesRelease() {
  #expect(SemanticVersion("1.2.0-beta")! < SemanticVersion("1.2.0")!)
  #expect(SemanticVersion("1.2.0")! > SemanticVersion("1.2.0-rc.1")!)
}
