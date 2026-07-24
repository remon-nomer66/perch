import Foundation

/// Deciding whether a registered artist is what is being listened to.
///
/// The match is deliberately loose — "if the name is in there, apply it" — because the
/// text it reads is written for people, not lookups: a player may report several artists
/// in one string ("A feat. B", "A, B"), and a browser tab's title glues the artist to the
/// song and the site ("Artist - Song - YouTube"), sometimes with no separator at all, as
/// many Japanese video pages do. So the name is sought both as a whole performer token —
/// split on the ways collaborators and titles are joined — and, for names of two
/// characters or more, as a plain substring, which is what catches the glued-together
/// titles.
enum ArtistMatch {
  /// Case-, accent-, and width-insensitive, trimmed. One representation, so "beyoncé",
  /// "BEYONCE", and the full-width "ＢＥＹＯＮＣＥ" all compare equal.
  static func normalize(_ string: String) -> String {
    string
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The performer tokens in a raw string, split on the separators that join
  /// collaborators (feat., &, ×, comma…) and the dashes and pipes a tab title puts
  /// between artist, song, and site. Each token is normalized.
  static func tokens(from raw: String) -> [String] {
    var scratch = normalize(raw)
    for separator in separators {
      scratch = scratch.replacingOccurrences(of: separator, with: "\u{1}")
    }
    return scratch.split(separator: "\u{1}")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// True when `name` is what `haystack` is about. An exact performer token matches at
  /// any length, so a one-word collaborator on either side of a feat. counts; a plain
  /// substring matches only for names of two characters or more, keeping a very short
  /// name from matching the inside of an unrelated word.
  static func matches(registered name: String, in haystack: String) -> Bool {
    let target = normalize(name)
    guard !target.isEmpty else { return false }
    if tokens(from: haystack).contains(target) { return true }
    guard target.count >= 2 else { return false }
    return normalize(haystack).contains(target)
  }

  // Applied after `normalize`, so full-width variants — which fold to ASCII — need not be
  // listed; the ideographic comma, which does not fold, is kept. Dashes are spaced so a
  // hyphenated name is not split down the middle.
  private static let separators = [
    " feat. ", " feat ", " ft. ", " ft ", " featuring ",
    " & ", " × ", " x ", " vs. ", " vs ",
    " / ", " - ", " – ", " — ",
    "|", ";", ",", "、",
  ]
}
