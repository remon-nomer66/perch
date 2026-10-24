import SwiftUI
import Testing

@testable import NotchKit

@Test @MainActor func aScreenChangeArrivingAfterStopBuildsNothing() {
  // Removing the observer does not recall a notification block the main queue already
  // holds. Rebuilt then, a stopped notch would leave a live catcher over the menu bar,
  // taking presses for a panel no longer there.
  let controller = NotchController { _ in EmptyView() }
  controller.stop()

  controller.screenParametersDidChange()

  #expect(!controller.hasWindows)
  #expect(!controller.hasUsableNotch)
}

@Test @MainActor func refreshingAStoppedNotchBuildsNothing() {
  let controller = NotchController { _ in EmptyView() }

  controller.refresh()

  #expect(!controller.hasWindows)
}
