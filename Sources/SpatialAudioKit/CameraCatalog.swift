import AVFoundation

/// The cameras head tracking can choose from, and word whenever that changes.
///
/// A protocol so the controller's switching — fall back on an unplug, return on a
/// reconnect — can be tested with cameras that come and go on command, without a
/// single real device.
@MainActor
public protocol CameraCatalog: AnyObject {
  /// Enumerates right now, in `CameraSelection.ordered` order. Asked afresh whenever a
  /// decision depends on what is plugged in at this moment, not on the last report.
  /// Cheap once the capture stack is up; see `loadCameras` for the first time.
  func currentCameras() -> [CameraDevice]
  /// The same list, for the first look in a process. That first enumeration loads
  /// CoreMediaIO and every camera plug-in on the system and was measured holding its
  /// thread for 0.2–1 s; an implementation should keep it off the main thread.
  func loadCameras() async -> [CameraDevice]
  /// Called on the main actor with the new list after every connect or disconnect.
  /// The list may be unchanged (an audio device came or went); listeners compare.
  var onChange: (@MainActor ([CameraDevice]) -> Void)? { get set }
}

extension CameraCatalog {
  public func loadCameras() async -> [CameraDevice] {
    currentCameras()
  }
}

/// The system's cameras, following AVFoundation's connect/disconnect notifications.
///
/// Building this only registers for notifications; nothing is enumerated until asked.
/// Enumerating only lists devices: no session is opened, so it neither lights the
/// camera nor asks for permission.
@MainActor
public final class SystemCameraCatalog: CameraCatalog {
  public var onChange: (@MainActor ([CameraDevice]) -> Void)?
  /// Kept for its lifetime alone: the tokens unregister when the catalog goes.
  private var observers: ObserverTokens?
  private let enumerateCameras: @Sendable () -> [CameraDevice]
  /// Whether anyone has looked yet. Until then a notification is not worth answering:
  /// nobody holds a list to correct, and answering would pay the slow first
  /// enumeration on the main thread — for an audio device coming and going, at that.
  private var hasListed = false

  /// - Parameters:
  ///   - center: where AVFoundation posts connect/disconnect. Injected for tests.
  ///   - enumerate: the enumeration itself. Injected so tests never touch a device.
  public init(
    center: NotificationCenter = .default,
    enumerate: @escaping @Sendable () -> [CameraDevice] = SystemCameraCatalog.enumerate
  ) {
    enumerateCameras = enumerate
    // Only Sendable values cross into the main actor: the device is read where the
    // notification lands, then dropped.
    let connected = center.addObserver(
      forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
    ) { [weak self] note in
      let device = (note.object as? AVCaptureDevice).flatMap { $0.isSuspended ? nil : $0 }
      let arrived = device.flatMap(CameraDevice.init(device:))
      MainActor.assumeIsolated { self?.devicesChanged(arrived: arrived, departedID: nil) }
    }
    let disconnected = center.addObserver(
      forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
    ) { [weak self] note in
      let departedID = (note.object as? AVCaptureDevice)?.uniqueID
      MainActor.assumeIsolated { self?.devicesChanged(arrived: nil, departedID: departedID) }
    }
    observers = ObserverTokens(center: center, tokens: [connected, disconnected])
  }

  public func currentCameras() -> [CameraDevice] {
    hasListed = true
    return enumerateCameras()
  }

  public func loadCameras() async -> [CameraDevice] {
    let enumerate = enumerateCameras
    let cameras = await Task.detached(priority: .userInitiated) { enumerate() }.value
    hasListed = true
    return cameras
  }

  private func devicesChanged(arrived: CameraDevice?, departedID: String?) {
    guard hasListed else { return }
    onChange?(
      CameraSelection.reconcile(enumerateCameras(), arrived: arrived, departedID: departedID)
    )
  }

  /// Every usable camera, in fallback order. A suspended camera — the built-in one
  /// behind a closed lid — is left out: it is connected but delivers nothing, and
  /// choosing it would only end in "no video".
  public nonisolated static func enumerate() -> [CameraDevice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: CameraDevice.discoverableTypes, mediaType: .video, position: .unspecified
    )
    return CameraSelection.ordered(
      discovery.devices.filter { !$0.isSuspended }.compactMap(CameraDevice.init(device:))
    )
  }
}

/// Notification tokens that unregister themselves on release. NotificationCenter is
/// thread-safe and the tokens are never mutated, so they may be torn down from
/// whatever thread lets the catalog go.
private final class ObserverTokens: @unchecked Sendable {
  private let center: NotificationCenter
  private let tokens: [any NSObjectProtocol]

  init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
    self.center = center
    self.tokens = tokens
  }

  deinit {
    tokens.forEach(center.removeObserver)
  }
}
