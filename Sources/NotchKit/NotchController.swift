import AppKit
import SwiftUI

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
  public private(set) var hasUsableNotch = false
  public var onUsableNotchChanged: ((Bool) -> Void)?
  /// Asked whether the closed bar is currently drawn at its widened size. Left unset,
  /// the bar is assumed always visible. When it answers false the hover target
  /// shrinks to the bare cutout: a host that keeps the notch bare until looked at
  /// must not have the invisible side reaches of the hidden bar react to the pointer.
  public var isBarVisible: (() -> Bool)?

  private let pointer = PointerMonitor()
  private var window: NotchWindow?
  private var geometry: ScreenNotchGeometry?
  /// The notch screen's frame, kept so the strip and the panel rect can be re-derived
  /// on every pointer event without asking AppKit for the screen list each time.
  private var screenFrame: CGRect?
  private var screenObserver: (any NSObjectProtocol)?
  private var presenter: NotchPresenter
  private let content: (NotchPresenter.Presentation) -> AnyView
  /// Read on every hit test so a change in the settings takes effect at once.
  private let appearance: () -> NotchAppearance

  public init(
    appearance: @escaping () -> NotchAppearance = { .default },
    @ViewBuilder content: @escaping (NotchPresenter.Presentation) -> some View
  ) {
    self.presenter = NotchPresenter()
    self.appearance = appearance
    self.content = { AnyView(content($0)) }
  }

  /// Safe to call again after `stop()`: the notch can be switched off and on from the
  /// settings without accumulating observers or windows.
  public func start() {
    stop()
    rebuild()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuild() }
    }

    pointer.onPointerMoved = { [weak self] location in
      MainActor.assumeIsolated { self?.pointerMoved(to: location) }
    }
    pointer.onClick = { [weak self] location in
      MainActor.assumeIsolated { self?.clicked(at: location) }
    }
    pointer.start()
  }

  /// Closes an open panel, for the moments the interface moves elsewhere — pressing
  /// the panel's own gear hands the stage to the settings window.
  public func dismiss() {
    presenter.handle(.dismiss)
    apply()
  }

  public func stop() {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    pointer.stop()
    window?.orderOut(nil)
    window = nil
    // A fresh presenter, so a panel left open does not reappear open when the notch
    // is switched back on later.
    presenter = NotchPresenter()
    if presentation != .closed { presentation = .closed }
  }

  // MARK: - Screens

  private func rebuild() {
    let screen = NSScreen.withNotch
    let geometry = screen?.notchGeometry
    self.geometry = geometry
    self.screenFrame = screen?.frame

    let usable = geometry != nil
    if usable != hasUsableNotch {
      hasUsableNotch = usable
      onUsableNotchChanged?(usable)
    }

    guard let screen, geometry != nil else {
      window?.orderOut(nil)
      window = nil
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
    apply()
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
    presenter.handle(.pointerMoved(isOverNotch: isOverNotch(location)))
    apply()
  }

  private func clicked(at location: CGPoint) {
    guard geometry != nil else { return }
    presenter.handle(
      .clicked(
        isOverNotch: isOverNotch(location),
        isInsidePanel: expandedRect.contains(location)
      )
    )
    apply()
  }

  /// A little slack: demanding pixel accuracy makes the target feel smaller than it
  /// looks.
  private func isOverNotch(_ location: CGPoint) -> Bool {
    guard let geometry else { return false }
    return Self.hoverTarget(
      barVisible: isBarVisible?() ?? true,
      notch: geometry.rect,
      appearance: appearance()
    )
    .insetBy(dx: -4, dy: -4)
    .contains(location)
  }

  /// What the pointer must reach to count as "over the notch", in global screen
  /// coordinates: the widened bar while it is drawn, but only the bare cutout while
  /// the host reports the bar hidden — an invisible target that reacts anyway reads
  /// as a haunted patch of menu bar.
  nonisolated static func hoverTarget(
    barVisible: Bool, notch: CGRect, appearance: NotchAppearance
  ) -> CGRect {
    barVisible ? appearance.closedRect(around: notch) : notch
  }

  private var expandedRect: CGRect {
    guard let geometry, let screenFrame else { return .zero }
    let size = appearance().expandedSize
    return CGRect(
      x: geometry.rect.midX - size.width / 2,
      y: screenFrame.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func apply() {
    if presentation != presenter.presentation {
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
    // The bar is drawn even while closed, but it must never intercept a click meant
    // for the menu bar behind it.
    window?.setInteractive(presenter.presentation == .opened)
  }

  fileprivate func body(_ presentation: NotchPresenter.Presentation) -> AnyView {
    content(presentation)
  }
}

private struct NotchHost: View {
  @ObservedObject var controller: NotchController

  var body: some View {
    controller.body(controller.presentation)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
