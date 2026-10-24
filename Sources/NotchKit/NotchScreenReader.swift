import AppKit
import os

/// Takes one reading of the notch screen from the live window list at a time, keeping
/// between readings the one thing a single list cannot tell: whether this screen's
/// desktop has been seen before (see `DesktopSighting`).
@MainActor
final class NotchScreenReader {
  /// One look at the notch screen: its window list, and where the screen sits.
  struct Look {
    let windows: [[String: Any]]
    let screenFrame: CGRect
    let safeAreaTop: CGFloat
    let primaryFrame: CGRect
  }

  private static let log = Logger(subsystem: "dev.perch.mac", category: "fullscreen")

  private let look: @MainActor () -> Look?
  private let ownPID: pid_t
  private let witness: FullScreenRule.MenuBarWitness
  private var sighting = DesktopSighting()

  convenience init() {
    self.init(
      look: NotchScreenReader.liveLook,
      ownPID: ProcessInfo.processInfo.processIdentifier,
      witness: .running
    )
  }

  /// Takes the look from elsewhere, so the memory can be exercised without a screen.
  init(
    look: @escaping @MainActor () -> Look?,
    ownPID: pid_t,
    witness: FullScreenRule.MenuBarWitness
  ) {
    self.look = look
    self.ownPID = ownPID
    self.witness = witness
  }

  func read() -> FullScreenReading {
    guard let look = look() else { return FullScreenReading(reason: .nothingToRead) }
    let frame = look.screenFrame
    let hadSeen = sighting.hasSeenDesktop(on: frame)
    let reading = FullScreenRule.read(
      windows: look.windows,
      screenFrame: frame,
      safeAreaTop: look.safeAreaTop,
      primaryFrame: look.primaryFrame,
      ownPID: ownPID,
      witness: witness,
      hasSeenDesktop: hadSeen
    )
    let next = sighting.noting(reading, on: frame)
    if sighting.sawDesktop, sighting.screenFrame != frame {
      Self.log.debug("Notch screen changed; its desktop is yet to be seen")
    }
    if next.hasSeenDesktop(on: frame), !hadSeen {
      Self.log.debug("Desktop seen on the notch screen")
    }
    sighting = next
    return reading
  }

  private static func liveLook() -> Look? {
    guard let screen = NSScreen.withNotch, let primary = NSScreen.screens.first,
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    return Look(
      windows: windows,
      screenFrame: screen.frame,
      safeAreaTop: screen.safeAreaInsets.top,
      primaryFrame: primary.frame
    )
  }
}
