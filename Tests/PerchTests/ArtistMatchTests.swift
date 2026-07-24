import Testing

@testable import Perch

@Test("An exact artist name matches")
func matchesExactName() {
  #expect(ArtistMatch.matches(registered: "YOASOBI", in: "YOASOBI"))
}

@Test("A collaborator on either side of a feat. matches")
func matchesEitherSideOfFeat() {
  #expect(ArtistMatch.matches(registered: "YOASOBI", in: "YOASOBI feat. 幾田りら"))
  #expect(ArtistMatch.matches(registered: "幾田りら", in: "YOASOBI feat. 幾田りら"))
}

@Test("Ampersand- and comma-separated performers match")
func matchesAmpersandAndComma() {
  #expect(ArtistMatch.matches(registered: "Bruno Mars", in: "Mark Ronson & Bruno Mars"))
  #expect(ArtistMatch.matches(registered: "B", in: "A, B"))
}

@Test("A browser tab title with dashes matches the artist token")
func matchesBrowserTitleTokens() {
  #expect(
    ArtistMatch.matches(
      registered: "Fujii Kaze",
      in: "Fujii Kaze - I Need U (Official Video) - YouTube"
    )
  )
}

@Test("A title that glues artist to song with no separator still matches as a substring")
func matchesGluedTitleAsSubstring() {
  #expect(
    ArtistMatch.matches(
      registered: "YOASOBI",
      in: "YOASOBI「アイドル」Official Music Video - YouTube"
    )
  )
}

@Test("Matching ignores case, accents, and full-width forms")
func matchesFoldingInsensitively() {
  #expect(ArtistMatch.matches(registered: "yoasobi", in: "YOASOBI"))
  #expect(ArtistMatch.matches(registered: "ＹＯＡＳＯＢＩ", in: "YOASOBI"))
  #expect(ArtistMatch.matches(registered: "Beyonce", in: "Beyoncé - Halo"))
}

@Test("An unrelated artist does not match")
func rejectsUnrelatedArtist() {
  #expect(!ArtistMatch.matches(registered: "Ado", in: "Vaundy - Odoriko"))
}

@Test("A one-character name matches only as a whole token, never as a substring")
func guardsAgainstOneCharacterSubstrings() {
  #expect(ArtistMatch.matches(registered: "A", in: "A feat. B"))  // whole token
  #expect(!ArtistMatch.matches(registered: "A", in: "Abba"))      // inside a word
}
