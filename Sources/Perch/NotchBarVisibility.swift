import NotchKit

/// Decides whether the closed bar is drawn at its widened size.
///
/// The view draws by this and the notch controller aims the pointer by it, so the two
/// read one answer. Each kept its own copy before, and the controller's had no notion
/// of the arrival announcement: in the quiet mode the announced bar stood widened on
/// screen while only the bare cutout under it answered the pointer.
enum NotchBarVisibility {
  /// The quiet mode keeps the bare notch and widens only while looked at — pointer on
  /// the notch, panel open — or for the few seconds after a device connects. A virtual
  /// notch is quiet whatever the display mode says: it rests as a sliver.
  static func isExtended(
    model: PanelModel,
    isVirtual: Bool,
    displayMode: NotchDisplayMode,
    presentation: NotchPresenter.Presentation
  ) -> Bool {
    guard model.hasContent else { return false }
    let isLookedAt = presentation != .closed || model.announcesArrival
    if isVirtual { return isLookedAt }
    switch displayMode {
    case .always: return true
    case .onHover: return isLookedAt
    }
  }
}
