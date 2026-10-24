import AppKit
import SwiftUI
import os

/// What the hosted view needs to draw the notch in one value: the state it is in,
/// where the cutout sits, and whether it was synthesised on a screen with none — the
/// last so the view can rest a virtual notch as a thin sliver rather than a full bar.
///
/// Passed through from the controller, which owns the geometry, so the view never has
/// to re-derive the cutout from `NSScreen` (where a virtual notch does not exist).
public struct NotchRender: Equatable, Sendable {
  public let presentation: NotchPresenter.Presentation
  public let notchRect: CGRect
  public let isVirtual: Bool

  public init(
    presentation: NotchPresenter.Presentation,
    notchRect: CGRect,
    isVirtual: Bool
  ) {
    self.presentation = presentation
    self.notchRect = notchRect
    self.isVirtual = isVirtual
  }
}

extension NSScreen {
  public var notchGeometry: ScreenNotchGeometry? {
    ScreenNotchGeometry.resolve(
      screenFrame: frame,
      safeAreaTop: safeAreaInsets.top,
      leftArea: auxiliaryTopLeftArea,
      rightArea: auxiliaryTopRightArea
    )
  }

  public static var withNotch: NSScreen? {
    screens.first { $0.notchGeometry != nil }
  }

  /// A notch made up over this screen's menu bar, for a display that has no real one.
  /// Nil when the screen genuinely has a cutout — that one is used instead.
  ///
  /// The menu bar height is read from the gap the visible frame leaves at the top, and
  /// floored so a globally auto-hidden menu bar still yields a sensible band to sit in.
  public func virtualNotchGeometry(width: CGFloat) -> ScreenNotchGeometry? {
    guard notchGeometry == nil else { return nil }
    let menuBarHeight = Swift.max(frame.maxY - visibleFrame.maxY, 24)
    return ScreenNotchGeometry.synthesized(
      screenFrame: frame, menuBarHeight: menuBarHeight, width: width
    )
  }
}

/// Hosts the notch panel on whichever screen has a notch, and reports when none does.
///
/// The application is a background agent, so losing the notch would otherwise leave it
/// with no way to be reached at all. Whoever owns the menu bar item watches
/// `hasUsableNotch` and shows one when this is false, regardless of the user's
/// preference.
@MainActor
public final class NotchController: ObservableObject {
  /// Published so the hosted view redraws when the notch opens or closes.
  @Published public private(set) var presentation: NotchPresenter.Presentation = .closed
  /// The notch cutout in *global screen coordinates* (bottom-left origin), exactly as
  /// `NSScreen` reports it. Hit testing stays in this space — the pointer location is
  /// global too — but a view hosted in the strip window must shift positions by the
  /// notch screen's own `minX` before drawing by this rect.
  @Published public private(set) var notchRect: CGRect = .zero
  /// Whether the notch now on screen was synthesised on a display with no cutout. The
  /// hosted view reads this to rest as a thin sliver instead of drawing a full bar.
  @Published public private(set) var isVirtualNotch = false
  public private(set) var hasUsableNotch = false
  public var onUsableNotchChanged: ((Bool) -> Void)?
  /// Asked whether the closed bar is currently drawn at its widened size. Left unset,
  /// the bar is assumed always visible. When it answers false the hover target
  /// shrinks to what is drawn instead — the bare cutout, or a virtual notch's sliver: a
  /// host that keeps the notch bare until looked at must not have the invisible side
  /// reaches of the hidden bar react to the pointer. It must be the very answer the
  /// hosted view widens the bar by, or the target and the drawing part ways.
  public var isBarVisible: (() -> Bool)?

  private static let log = Logger(subsystem: "dev.perch.mac", category: "notch")

  private let pointer = PointerMonitor()
  private var window: NotchWindow?
  /// Stands over the closed bar so a press on it is ours rather than the menu bar's;
  /// see `NotchClickCatcher`. Lives and dies with the strip.
  private var catcher: NotchClickCatcher?
  /// The last answer to "is the pointer over the notch", kept only so the log records
  /// when it changes rather than ten times a second.
  private var lastOverNotch: Bool?
  private var doubleClicks = DoubleClickFilter()
  /// Whether `start()` is in effect. `refresh()` leans on it so a settings change
  /// cannot rebuild a notch the user has switched off.
  private var isRunning = false
  private var geometry: ScreenNotchGeometry?
  /// The notch screen's frame, kept so the strip and the panel rect can be re-derived
  /// on every pointer event without asking AppKit for the screen list each time.
  private var screenFrame: CGRect?
  private var screenObserver: (any NSObjectProtocol)?
  private var presenter: NotchPresenter
  private let content: (NotchRender) -> AnyView
  /// Read on every hit test so a change in the settings takes effect at once.
  private let appearance: () -> NotchAppearance
  /// Read on every rebuild: when no screen has a real notch and this answers true, one
  /// is synthesised so the interface stays reachable. Left unset, a display without a
  /// cutout simply has no notch, as before.
  private let virtualNotchEnabled: () -> Bool

  /// The made-up width of a virtual notch. A screen with no cutout has no true width
  /// to measure, so a nominal one is used — close to a real notch, wide enough to
  /// centre the panel and catch the pointer, without spanning the menu bar.
  nonisolated static let virtualNotchWidth: CGFloat = 220

  public init(
    appearance: @escaping () -> NotchAppearance = { .default },
    virtualNotchEnabled: @escaping () -> Bool = { false },
    @ViewBuilder content: @escaping (NotchRender) -> some View
  ) {
    self.presenter = NotchPresenter()
    self.appearance = appearance
    self.virtualNotchEnabled = virtualNotchEnabled
    self.content = { AnyView(content($0)) }
  }

  /// Safe to call again after `stop()`: the notch can be switched off and on from the
  /// settings without accumulating observers or windows.
  public func start() {
    stop()
    // Set before building: `rebuild()` refuses to run without it.
    isRunning = true
    rebuild()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screenParametersDidChange() }
    }

    pointer.onPointerMoved = { [weak self] location in
      MainActor.assumeIsolated { self?.pointerMoved(to: location) }
    }
    pointer.onClick = { [weak self] click in
      MainActor.assumeIsolated { self?.clicked(click) }
    }
    pointer.start()
    Self.log.debug("start: usable notch \(self.hasUsableNotch), virtual \(self.isVirtualNotch)")
  }

  /// The screen observer's handler. Removing the observer in `stop()` does not recall a
  /// block the main queue already holds, so one can still arrive after it — and, acted
  /// on, would rebuild a stopped notch with a live catcher over the menu bar.
  func screenParametersDidChange() {
    guard isRunning else { return }
    rebuild()
  }

  /// Whether any window of the notch is up. Read by the tests, which must not put one
  /// on screen to find out.
  var hasWindows: Bool { window != nil || catcher != nil }

  /// Re-evaluates which screen hosts the notch without tearing anything down, for the
  /// moments the geometry did not change but the choice of it did — the virtual-notch
  /// setting being switched while the app runs. A no-op while stopped, so toggling it
  /// with the notch off does not conjure a window.
  public func refresh() {
    guard isRunning else { return }
    rebuild()
  }

  /// Closes an open panel, for the moments the interface moves elsewhere — pressing
  /// the panel's own gear hands the stage to the settings window.
  public func dismiss() {
    presenter.handle(.dismiss)
    apply()
  }

  public func stop() {
    if isRunning { Self.log.debug("stop") }
    isRunning = false
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    pointer.stop()
    tearDownWindows()
    lastOverNotch = nil
    // A fresh presenter, so a panel left open does not reappear open when the notch
    // is switched back on later.
    presenter = NotchPresenter()
    doubleClicks = DoubleClickFilter()
    if presentation != .closed { presentation = .closed }
  }

  // MARK: - Screens

  private func rebuild() {
    // Every route here is meant for a running notch; one that arrives otherwise must
    // not conjure windows the next `stop()` would never be asked to take down.
    guard isRunning else { return }
    // A real notch wins wherever one exists; only when none does, and the setting asks
    // for it, is a notch synthesised over the main screen's menu bar.
    let screen: NSScreen?
    let geometry: ScreenNotchGeometry?
    if let real = NSScreen.withNotch {
      screen = real
      geometry = real.notchGeometry
    } else if virtualNotchEnabled(), let main = NSScreen.main ?? NSScreen.screens.first {
      screen = main
      geometry = main.virtualNotchGeometry(width: Self.virtualNotchWidth)
    } else {
      screen = nil
      geometry = nil
    }
    self.geometry = geometry
    self.screenFrame = screen?.frame

    let usable = geometry != nil
    if usable != hasUsableNotch {
      hasUsableNotch = usable
      onUsableNotchChanged?(usable)
    }
    let virtual = geometry?.isVirtual ?? false
    if virtual != isVirtualNotch { isVirtualNotch = virtual }

    guard let screen, geometry != nil else {
      tearDownWindows()
      return
    }

    let strip = Self.stripRect(
      screenFrame: screen.frame,
      expandedHeight: appearance().expandedHeight
    )
    let window: NotchWindow
    if let existing = self.window {
      window = existing
      window.setFrame(strip, display: false)
    } else {
      window = NotchWindow(screenFrame: strip)
      // The hosting view is created once and kept for the window's whole life:
      // replacing it on every screen-parameter notification would throw away the
      // SwiftUI view's @State — measured label widths, an arrival announcement
      // mid-countdown — when only the geometry moved. The root view reads everything
      // it draws from the controller, so it needs no rebuilding to follow a change.
      window.contentView = NSHostingView(rootView: NotchHost(controller: self))
    }
    window.orderFrontRegardless()
    self.window = window
    let catcher = self.catcher ?? NotchClickCatcher()
    catcher.orderFrontRegardless()
    self.catcher = catcher
    apply()
  }

  private func tearDownWindows() {
    window?.orderOut(nil)
    window = nil
    catcher?.orderOut(nil)
    catcher = nil
  }

  /// Room kept under the panel so its shadow can fade out inside the window instead
  /// of being cut off at the frame's edge.
  private nonisolated static let stripShadowRoom: CGFloat = 60

  /// The strip of screen the window covers: the top of the notch screen, tall enough
  /// for the expanded panel and its shadow. Only the top strip is covered — a window
  /// across the whole screen would swallow every click that lands outside the panel.
  nonisolated static func stripRect(screenFrame: CGRect, expandedHeight: CGFloat) -> CGRect {
    let height = expandedHeight + stripShadowRoom
    return CGRect(
      x: screenFrame.minX,
      y: screenFrame.maxY - height,
      width: screenFrame.width,
      height: height
    )
  }

  // MARK: - Pointer

  private func pointerMoved(to location: CGPoint) {
    guard geometry != nil else { return }
    let overNotch = isOverNotch(location)
    if overNotch != lastOverNotch {
      lastOverNotch = overNotch
      Self.log.debug("pointer over notch: \(overNotch)")
    }
    presenter.handle(.pointerMoved(isOverNotch: overNotch))
    apply()
  }

  private func clicked(_ click: PointerClick) {
    guard geometry != nil else { return }
    let overNotch = isOverNotch(click.location)
    let insidePanel = panelTarget.contains(click.location)
    let catcherNumber = catcher?.windowNumber
    Self.log.debug(
      """
      click via \(click.route.rawValue, privacy: .public) at \
      (\(Double(click.location.x)), \(Double(click.location.y))), count \
      \(click.clickCount): over notch \(overNotch), on catcher \
      \(click.landed(onWindow: catcherNumber)), inside panel \(insidePanel)
      """
    )
    let event = Self.presenterEvent(
      for: click,
      presentation: presenter.presentation,
      catcherWindowNumber: catcherNumber,
      isOverNotch: overNotch,
      isInsidePanel: insidePanel
    )
    guard doubleClicks.pass(event, of: click, to: &presenter) else {
      Self.log.debug("click held back: repeats the press that just opened or closed")
      return
    }
    apply()
  }

  private func isOverNotch(_ location: CGPoint) -> Bool {
    currentNotchTarget?.contains(location) ?? false
  }

  /// What the pointer must reach right now, slack included: the bar exactly as the view
  /// draws it in the current state. An invisible target that reacts anyway reads as a
  /// haunted patch of menu bar, and a drawn one that does not reads as a dead click.
  private var currentNotchTarget: CGRect? {
    guard let geometry else { return nil }
    return Self.notchTarget(
      barVisible: isBarVisible?() ?? true,
      presentation: presenter.presentation,
      notch: geometry.rect,
      isVirtual: geometry.isVirtual,
      appearance: appearance()
    )
  }

  private var panelTarget: CGRect {
    guard let geometry, let screenFrame else { return .zero }
    return Self.panelTarget(
      notch: geometry.rect, screenFrame: screenFrame, appearance: appearance()
    )
  }

  private func apply() {
    if presentation != presenter.presentation {
      Self.log.debug(
        """
        presentation \(String(describing: self.presentation), privacy: .public) -> \
        \(String(describing: self.presenter.presentation), privacy: .public)
        """
      )
      presentation = presenter.presentation
      // One clean frame after the open/close spring settles. On a transparent
      // window the animation's last partial frame can stay on the glass; pointer
      // movement then re-composites cursor-sized patches from the current surface,
      // visibly erasing the panel's shadow along the pointer's path.
      let window = window
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        window?.contentView?.needsDisplay = true
      }
    }
    let rect = geometry?.rect ?? .zero
    if notchRect != rect { notchRect = rect }
    // The expanded height is adjustable while everything is on screen, and the
    // settings promise the change shows as the slider moves. The strip was sized at
    // build time; grown past it the panel would be cut at the window's bottom edge —
    // while the hit test, which reads the appearance live, kept honouring the
    // invisible remainder. Following it here keeps the two in step, and the check is
    // two rect compares on the pointer's cadence.
    if let window, let screenFrame {
      let strip = Self.stripRect(
        screenFrame: screenFrame,
        expandedHeight: appearance().expandedHeight
      )
      if window.frame != strip { window.setFrame(strip, display: true) }
    }
    // The bar is drawn even while closed, but the strip must never intercept a click
    // meant for the menu bar behind it; only the catcher, over the bar alone, does.
    // Both follow the state on every call — the pointer's cadence and the poll's — so a
    // bar that widened or shrank with the pointer still is caught up within a tick.
    window?.setInteractive(presenter.presentation == .opened)
    catcher?.cover(
      screenFrame.flatMap { screenFrame in
        currentNotchTarget.flatMap { target in
          Self.catcherFrame(
            presentation: presenter.presentation, notchTarget: target, screenFrame: screenFrame
          )
        }
      }
    )
  }

  fileprivate func body(_ render: NotchRender) -> AnyView {
    content(render)
  }
}

private struct NotchHost: View {
  @ObservedObject var controller: NotchController

  var body: some View {
    controller.body(
      NotchRender(
        presentation: controller.presentation,
        notchRect: controller.notchRect,
        isVirtual: controller.isVirtualNotch
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
