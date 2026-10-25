import AppKit

/// Watches where the pointer is, and whether a click landed outside our window.
///
/// Two monitors are needed. A global monitor never sees events aimed at our own
/// window, and a local monitor never sees events aimed at anyone else's; the notch has
/// to react in both cases. Only mouse events are observed, so no accessibility or
/// input monitoring permission is ever requested.
@MainActor
public final class PointerMonitor {
  public var onPointerMoved: ((CGPoint) -> Void)?
  public var onClick: ((PointerClick) -> Void)?

  private var globalMonitors: [Any] = []
  private var localMonitor: Any?
  private var poller: Timer?

  public init() {}

  public func start() {
    stop()

    let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: movement, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.reportPointer() }
    }) {
      globalMonitors.append(monitor)
    }
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
      let clickCount = event.clickCount
      MainActor.assumeIsolated {
        self?.reportClick(route: .global, clickCount: clickCount, windowNumber: nil)
      }
    }) {
      globalMonitors.append(monitor)
    }

    localMonitor = NSEvent.addLocalMonitorForEvents(matching: movement.union(clicks)) { [weak self] event in
      // Clicks must be reported as clicks here too: once the panel is open the
      // window is interactive, so a click on the notch arrives through this
      // monitor — and closing on that click is how the panel is dismissed from
      // where the pointer already is. While closed, a press on the bar lands on the
      // click catcher and arrives here as well, which is the route that opens it.
      let isClick = clicks.contains(NSEvent.EventTypeMask(type: event.type))
      // Read only for a press: asking anything else for its click count raises.
      let clickCount = isClick ? event.clickCount : 0
      let windowNumber = event.windowNumber
      MainActor.assumeIsolated {
        if isClick {
          self?.reportClick(route: .local, clickCount: clickCount, windowNumber: windowNumber)
        } else {
          self?.reportPointer()
        }
      }
      return event
    }

    // A safety net for configurations where the global monitor delivers nothing.
    // Cheap enough to leave running: one location read a tenth of a second.
    let poller = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.reportPointer() }
    }
    RunLoop.main.add(poller, forMode: .common)
    self.poller = poller
  }

  public func stop() {
    globalMonitors.forEach(NSEvent.removeMonitor)
    globalMonitors = []
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    localMonitor = nil
    poller?.invalidate()
    poller = nil
  }

  private func reportPointer() {
    onPointerMoved?(NSEvent.mouseLocation)
  }

  /// The location is read from `NSEvent.mouseLocation` on both routes, so the two speak
  /// the same global coordinates without converting from a window that may be gone.
  /// AppKit numbers "no window" 0, which is kept as no window rather than a number.
  private func reportClick(route: PointerClick.Route, clickCount: Int, windowNumber: Int?) {
    onClick?(
      PointerClick(
        location: NSEvent.mouseLocation,
        route: route,
        clickCount: clickCount,
        windowNumber: windowNumber.flatMap { $0 > 0 ? $0 : nil }
      )
    )
  }
}
