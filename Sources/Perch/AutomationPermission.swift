import Foundation

/// Remembers that macOS refused an automation request, so the settings can say why
/// site rules or the now-playing readout went quiet instead of failing silently.
///
/// Denial is only observable at the moment a query fails — there is no API to ask in
/// advance — so the flags latch when a refusal is seen. The browser flag clears again
/// on the next browser that answers, since a grant made later in System Settings is
/// likewise only observable through a query succeeding.
@MainActor
final class AutomationPermission: ObservableObject {
  static let shared = AutomationPermission()

  /// A browser refused its Apple Events: site rules cannot see any tabs.
  @Published private(set) var browserDenied = false
  /// A player refused its Apple Events: the now-playing readout and the transport
  /// commands cannot reach it.
  @Published private(set) var playerDenied = false

  func noteBrowserDenied() { browserDenied = true }
  func noteBrowserAnswered() { browserDenied = false }
  func notePlayerDenied() { playerDenied = true }
}
