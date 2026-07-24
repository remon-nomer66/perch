import Foundation

/// A dotted numeric version — `major.minor.patch` — parsed leniently from a release
/// tag. A leading `v`, missing trailing components, and any pre-release/build suffix
/// after the numeric core are tolerated, so `"v1.2"` and `"1.2.0-beta.1+42"` both read.
///
/// Comparison is on the numeric core; a pre-release suffix is treated as *earlier* than
/// the same core without one, so `1.2.0-beta < 1.2.0`.
struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int
  /// True when the tag carried a pre-release suffix (a `-…` after the numeric core).
  let isPreRelease: Bool

  init(major: Int, minor: Int, patch: Int, isPreRelease: Bool = false) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.isPreRelease = isPreRelease
  }

  /// Parses `"v1.2.3"`, `"1.2"`, `"1"`, `"1.2.3-beta.1"`, `"1.2.3+build"`. Returns nil
  /// when there is no leading numeric component, or a present component is non-numeric.
  init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = text.first, first == "v" || first == "V" { text.removeFirst() }
    guard !text.isEmpty else { return nil }

    // Split the numeric core off any pre-release (`-`) or build (`+`) metadata.
    let core: Substring
    let isPre: Bool
    if let dash = text.firstIndex(of: "-") {
      core = text[text.startIndex..<dash]
      isPre = true
    } else if let plus = text.firstIndex(of: "+") {
      core = text[text.startIndex..<plus]
      isPre = false
    } else {
      core = text[...]
      isPre = false
    }

    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard let first = parts.first, let major = Int(first) else { return nil }
    // A missing component is zero; a present-but-unparseable one fails the whole parse
    // rather than being silently read as zero.
    func component(_ index: Int) -> Int? {
      guard index < parts.count else { return 0 }
      return Int(parts[index])
    }
    guard let minor = component(1), let patch = component(2) else { return nil }
    self.init(major: major, minor: minor, patch: patch, isPreRelease: isPre)
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
    // Same core: a pre-release precedes the final release.
    if lhs.isPreRelease != rhs.isPreRelease { return lhs.isPreRelease }
    return false
  }

  var description: String { "\(major).\(minor).\(patch)" }
}
