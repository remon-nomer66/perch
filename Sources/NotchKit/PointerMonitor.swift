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
  public var onClick: ((CGPoint) -> Void)?

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
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.reportClick() }
    }) {
      globalMonitors.append(monitor)
    }

    localMonitor = NSEvent.addLocalMonitorForEvents(matching: movement.union(clicks)) { [weak self] event in
      MainActor.assumeIsolated {
        // Clicks must be reported as clicks here too: once the panel is open the
        // window is interactive, so a click on the notch arrives through this
        // monitor — and closing on that click is how the panel is dismissed from
        // where the pointer already is.
        if clicks.contains(NSEvent.EventTypeMask(type: event.type)) {
          self?.reportClick()
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

  private func reportClick() {
    onClick?(NSEvent.mouseLocation)
  }
}
