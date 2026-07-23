import Foundation
import TandemCore
import TandemSession

/// Gives the headset's touch panel back its effect on playback.
///
/// While the control channel is held open, the headset stops sending its play and skip
/// gestures as Bluetooth media keys and instead reports them over the channel — volume
/// it still applies itself. This listens for those reports and re-issues the ones the
/// headset withheld, through the same player transport the notch buttons use, so a
/// double-tap or swipe controls the music again. Nothing is inferred from a model name:
/// each report names its own action, and only the transport ones are acted on.
@MainActor
final class MediaGestureForwarder {
  /// The player controls to drive. Injected so this stays unaware of how playback is
  /// reached, and testable without a real player.
  struct Transport {
    let playPause: () -> Void
    let next: () -> Void
    let previous: () -> Void
  }

  private let service: SessionService
  private let transport: Transport
  private var task: Task<Void, Never>?

  init(service: SessionService, transport: Transport) {
    self.service = service
    self.transport = transport
  }

  func start() {
    task?.cancel()
    task = Task { [service, transport] in
      let notifications = await service.session.deviceNotifications
      for await frame in notifications {
        guard
          let gesture = TandemMediaGesture.decode(payload: frame.payload),
          gesture.isTransport
        else { continue }
        switch gesture {
        case .play, .pause: transport.playPause()
        case .next: transport.next()
        case .previous: transport.previous()
        case .volumeUp, .volumeDown: break  // the headset changes its own volume
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}
