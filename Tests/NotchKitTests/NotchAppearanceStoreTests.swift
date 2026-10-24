import Foundation
import Testing

@testable import NotchKit

/// The key the store keeps its archive under.
private let archiveKey = "NotchAppearance"

/// An archive as written before the bar was drawn per side: no marker, the old 76/52.
private let oldArchive = Data(
  """
  {
    "leadingExtension": 76,
    "trailingExtension": 52,
    "closedHeightIncrease": 0,
    "restingHeight": 10,
    "expandedWidth": 640,
    "expandedHeight": 200,
    "closedBottomCornerRadius": 12,
    "expandedBottomCornerRadius": 22,
    "topCornerRadius": 10
  }
  """.utf8
)

/// A defaults suite of its own per test, removed afterwards.
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
  let suite = "dev.perch.tests.notch-appearance.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  try body(defaults)
}

@Test @MainActor func anOldArchiveIsReadAsShownButLeftAsWritten() {
  // Reading is not a change of mind: the archive is rewritten only when the owner
  // changes something, so an app downgraded again still finds what it wrote.
  withDefaults { defaults in
    defaults.set(oldArchive, forKey: archiveKey)

    let store = NotchAppearanceStore(defaults: defaults)

    #expect(store.appearance.leadingExtension == 64)
    #expect(store.appearance.trailingExtension == 64)
    #expect(defaults.data(forKey: archiveKey) == oldArchive)
  }
}

@Test @MainActor func aChangeIsSavedMarkedAsPerSide() throws {
  try withDefaults { defaults in
    defaults.set(oldArchive, forKey: archiveKey)
    let store = NotchAppearanceStore(defaults: defaults)

    store.appearance.leadingExtension = 90
    store.appearance.trailingExtension = 40

    let saved = try #require(defaults.data(forKey: archiveKey))
    let fields = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(fields["drawsSidesSeparately"] as? Bool == true)
    // Read back, the two reaches stay apart rather than being evened out again.
    let reloaded = NotchAppearanceStore(defaults: defaults)
    #expect(reloaded.appearance.leadingExtension == 90)
    #expect(reloaded.appearance.trailingExtension == 40)
  }
}
