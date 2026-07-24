import AppKit
import Foundation
import PlayerBridge

/// Which sites the running browsers are showing, asked over Apple Events — the same
/// channel the now-playing readout uses for the music players.
///
/// Every window's front tab counts, not just the focused window's: a video parked on
/// a second display keeps matching while the work happens elsewhere. A tab buried
/// behind another tab does not — it is not being watched. Only browsers that are
/// already running are asked; scripting one that is not would launch it.
///
/// The scripts run through an `AppleEventQueue`, never on the main thread: a browser
/// sitting on its automation-permission prompt holds the Apple Event for as long as
/// the dialog stays up, and that wait must not be the whole app's. `NSAppleScript` is
/// documented as not thread-safe, so each instance is created, run, and discarded
/// inside a single serial-queue item — it never crosses a thread and never runs
/// alongside another.
@MainActor
enum SiteWatcher {
  /// The browsers that can be asked. Chromium-family browsers speak the same dialect
  /// under their own names; minimised windows are nobody's viewing.
  private static let browsers: [String: String] = [
    "com.apple.Safari":
      #"tell application "Safari" to return URL of current tab of (every window whose visible is true and miniaturized is false)"#,
    "com.google.Chrome":
      #"tell application "Google Chrome" to return URL of active tab of (every window whose minimized is false)"#,
    "com.microsoft.edgemac":
      #"tell application "Microsoft Edge" to return URL of active tab of (every window whose minimized is false)"#,
    "com.brave.Browser":
      #"tell application "Brave Browser" to return URL of active tab of (every window whose minimized is false)"#,
  ]

  /// The same windows, asked for their front tab's title instead of its URL — the artist
  /// a video page shows lives there, where the player scripting APIs cannot reach it.
  private static let browserTitleScripts: [String: String] = [
    "com.apple.Safari":
      #"tell application "Safari" to return name of current tab of (every window whose visible is true and miniaturized is false)"#,
    "com.google.Chrome":
      #"tell application "Google Chrome" to return title of active tab of (every window whose minimized is false)"#,
    "com.microsoft.edgemac":
      #"tell application "Microsoft Edge" to return title of active tab of (every window whose minimized is false)"#,
    "com.brave.Browser":
      #"tell application "Brave Browser" to return title of active tab of (every window whose minimized is false)"#,
  ]

  private static let queue = AppleEventQueue(label: "Perch.SiteWatcher")
  private static let gate = AppleEventQueue.Gate()
  /// A gate of its own: the title query and the host query run on their own cadences and
  /// must only skip for their own stuck rounds.
  private static let titleGate = AppleEventQueue.Gate()

  /// The hosts on every running browser window's front tab. Empty when no known
  /// browser runs, none shows a window, automation has not been granted yet, or the
  /// browsers take longer to answer than a rule pass will wait.
  static func visibleTabHosts() async -> [String] {
    // Which browsers run is read here on the main actor, where NSWorkspace lives;
    // only the script execution crosses to the queue.
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let scripts = browsers.filter { running.contains($0.key) }.map(\.value)
    guard !scripts.isEmpty else { return [] }
    return await queue.perform(gate: gate, fallback: []) { hosts(from: scripts) }
  }

  /// The titles on every running browser window's front tab — but only the browsers that
  /// are audibly playing, when `audible` says who is: a tab's title only proves what is
  /// being listened to while its browser makes sound. A search page naming an artist must
  /// not pass for listening. `audible` nil means the outputting processes could not be
  /// read (older macOS); then every running browser is asked, as before.
  /// Same access and caveats as `visibleTabHosts` otherwise: empty when no candidate
  /// browser runs, none shows a window, automation has not been granted, or the browsers
  /// take longer to answer than a rule pass waits.
  static func visibleTabTitles(audible: Set<String>? = nil) async -> [String] {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let scripts = browserTitleScripts
      .filter { running.contains($0.key) }
      .filter { audible == nil || browserIsAudible($0.key, outputting: audible ?? []) }
      .map(\.value)
    guard !scripts.isEmpty else { return [] }
    return await queue.perform(gate: titleGate, fallback: []) { titles(from: scripts) }
  }

  /// Whether this browser is among the processes currently outputting audio. A browser's
  /// sound leaves from its helper processes, not the app itself — Chromium helpers carry
  /// the browser's bundle ID plus a suffix, Safari's media runs in the WebKit GPU
  /// process — so the match is by dotted prefix, with the WebKit family standing in for
  /// Safari. Pure, hence testable.
  nonisolated static func browserIsAudible(_ browserID: String, outputting: Set<String>) -> Bool {
    if browserID == "com.apple.Safari" {
      return outputting.contains { $0 == browserID || $0.hasPrefix("com.apple.WebKit") }
    }
    return outputting.contains { $0 == browserID || $0.hasPrefix(browserID + ".") }
  }

  /// The Apple Events denial, `errAEEventNotPermitted`: automation for the target
  /// was refused in System Settings (or the consent dialog was dismissed).
  private nonisolated static let eventNotPermitted = -1743

  /// Runs on the queue. The hosts on the front tabs, from the URLs the browsers report.
  private nonisolated static func hosts(from scripts: [String]) -> [String] {
    rawStrings(from: scripts).compactMap { URL(string: $0)?.host?.lowercased() }
  }

  /// Runs on the queue. The front tabs' titles, verbatim — an artist name is sought
  /// inside them, so they are not parsed here.
  private nonisolated static func titles(from scripts: [String]) -> [String] {
    rawStrings(from: scripts)
  }

  /// Runs each browser's script and gathers the string list it returns. A browser whose
  /// script errors — permission not granted, above all — contributes nothing rather than
  /// failing the others. A refusal is reported so the rules screen can say why
  /// browser-driven rules stopped matching; a browser answering clears it again, that
  /// being the only way a later grant shows itself.
  private nonisolated static func rawStrings(from scripts: [String]) -> [String] {
    var values: [String] = []
    var sawDenial = false
    var sawAnswer = false
    for source in scripts {
      guard let script = NSAppleScript(source: source) else { continue }
      var error: NSDictionary?
      let result = script.executeAndReturnError(&error)
      guard error == nil else {
        if error?[NSAppleScript.errorNumber] as? Int == eventNotPermitted { sawDenial = true }
        continue
      }
      sawAnswer = true
      values.append(contentsOf: strings(from: result))
    }
    if sawDenial || sawAnswer {
      // A denial outweighs another browser answering: as long as any browser is
      // refused, some rules are blind and the warning has cause to stand.
      let denied = sawDenial
      Task { @MainActor in
        denied
          ? AutomationPermission.shared.noteBrowserDenied()
          : AutomationPermission.shared.noteBrowserAnswered()
      }
    }
    return values
  }

  /// A single window comes back as a bare string, several as a list; flatten both.
  private nonisolated static func strings(from descriptor: NSAppleEventDescriptor) -> [String] {
    if let value = descriptor.stringValue { return [value] }
    guard descriptor.numberOfItems > 0 else { return [] }
    return (1...descriptor.numberOfItems).flatMap { index in
      descriptor.atIndex(index).map(strings(from:)) ?? []
    }
  }

  /// A registered `example.com` matches the host `example.com` and every subdomain.
  /// Both sides shed a leading `www.` — it names the same site, and rules stored by
  /// an earlier build may still carry it. Pure, hence `nonisolated`: the rule matcher
  /// calls it off the main actor.
  nonisolated static func matches(hosts: [String], sites: [String]) -> Bool {
    hosts.contains { host in
      let host = strippingWWW(host.lowercased())
      return sites.contains { site in
        let site = strippingWWW(site.lowercased())
        return !site.isEmpty && (host == site || host.hasSuffix("." + site))
      }
    }
  }

  /// What a typed entry becomes before being registered: the host alone, lowercased,
  /// without the `www.` no one means as part of the site, and without the userinfo,
  /// port, and path a pasted URL drags along — any of which would make the entry
  /// compare unequal to the bare hosts the browsers report, forever. Anything
  /// hostless is rejected.
  static func normalizedSite(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let host: String?
    if trimmed.contains("://") {
      // URL.host already excludes userinfo, port, and path.
      host = URL(string: trimmed)?.host
    } else {
      var bare = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
      if let at = bare.lastIndex(of: "@") { bare = String(bare[bare.index(after: at)...]) }
      if let colon = bare.firstIndex(of: ":") { bare = String(bare[..<colon]) }
      host = bare
    }
    guard let host else { return nil }
    let candidate = strippingWWW(host)
    guard candidate.contains("."), !candidate.contains(" ") else { return nil }
    return candidate
  }

  nonisolated private static func strippingWWW(_ host: String) -> String {
    host.hasPrefix("www.") ? String(host.dropFirst("www.".count)) : host
  }
}
