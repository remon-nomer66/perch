import AppKit
import Foundation
import IOBluetooth

/// What the session needs from Classic Bluetooth connection reporting. Abstracted so
/// the event translation in `SessionService` can be exercised without IOBluetooth.
public protocol BluetoothConnectionObserving: Sendable {
  var changes: AsyncStream<BluetoothConnectionObserver.Change> { get }
  func start()
  func stop()
}

/// Reports Classic Bluetooth connections and disconnections.
///
/// `IOBluetoothDevice` posts these per device once registered, so a device has to be
/// seen connecting before its disconnection can be observed. The connection notifier
/// is global and registers the per-device one as devices appear.
public final class BluetoothConnectionObserver: NSObject, BluetoothConnectionObserving,
  @unchecked Sendable
{
  public enum Change: Equatable, Sendable {
    case connected(DeviceIdentity)
    case disconnected(DeviceIdentity)
  }

  private let lock = NSLock()
  private var continuation: AsyncStream<Change>.Continuation?
  private var connectionNotification: IOBluetoothUserNotification?
  private var disconnectionNotifications: [String: IOBluetoothUserNotification] = [:]

  public private(set) lazy var changes: AsyncStream<Change> = {
    let (stream, continuation) = AsyncStream<Change>.makeStream(
      bufferingPolicy: .bufferingNewest(16)
    )
    lock.withLock { self.continuation = continuation }
    return stream
  }()

  public func start() {
    let notification = IOBluetoothDevice.register(
      forConnectNotifications: self,
      selector: #selector(deviceConnected(_:device:))
    )
    lock.withLock { connectionNotification = notification }

    // Devices already connected at launch never fire the connect notification, so
    // register for their disconnection now.
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    for device in paired where device.isConnected() {
      watchForDisconnection(device)
    }
  }

  public func stop() {
    lock.withLock {
      connectionNotification?.unregister()
      connectionNotification = nil
      disconnectionNotifications.values.forEach { $0.unregister() }
      disconnectionNotifications.removeAll()
    }
  }

  @objc private func deviceConnected(
    _ notification: IOBluetoothUserNotification,
    device: IOBluetoothDevice
  ) {
    watchForDisconnection(device)
    guard let address = device.addressString else { return }
    yield(.connected(DeviceIdentity(address)))
  }

  @objc private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification,
    device: IOBluetoothDevice
  ) {
    guard let address = device.addressString else { return }
    lock.withLock {
      disconnectionNotifications.removeValue(forKey: address)?.unregister()
    }
    yield(.disconnected(DeviceIdentity(address)))
  }

  private func watchForDisconnection(_ device: IOBluetoothDevice) {
    guard let address = device.addressString else { return }
    let notification = device.register(
      forDisconnectNotification: self,
      selector: #selector(deviceDisconnected(_:device:))
    )
    lock.withLock {
      disconnectionNotifications[address]?.unregister()
      disconnectionNotifications[address] = notification
    }
  }

  private func yield(_ change: Change) {
    let continuation = lock.withLock { self.continuation }
    continuation?.yield(change)
  }
}

/// What the session needs from sleep/wake reporting. Abstracted so the event
/// translation in `SessionService` can be exercised without the workspace.
public protocol PowerObserving: Sendable {
  var changes: AsyncStream<PowerObserver.Change> { get }
  func start()
  func stop()
}

/// Reports system sleep and wake.
///
/// The session has to be torn down before sleep rather than discovered broken after
/// it, so this listens for the workspace notifications rather than polling.
public final class PowerObserver: PowerObserving, @unchecked Sendable {
  public enum Change: Equatable, Sendable {
    case willSleep
    case didWake
  }

  private let lock = NSLock()
  private var continuation: AsyncStream<Change>.Continuation?
  private var tokens: [NSObjectProtocol] = []

  public init() {}

  public private(set) lazy var changes: AsyncStream<Change> = {
    let (stream, continuation) = AsyncStream<Change>.makeStream(
      bufferingPolicy: .bufferingNewest(4)
    )
    lock.withLock { self.continuation = continuation }
    return stream
  }()

  public func start() {
    let center = NSWorkspace.shared.notificationCenter
    let sleep = center.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in self?.yield(.willSleep) }
    let wake = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in self?.yield(.didWake) }
    lock.withLock { tokens = [sleep, wake] }
  }

  public func stop() {
    let center = NSWorkspace.shared.notificationCenter
    let observed = lock.withLock {
      defer { tokens = [] }
      return tokens
    }
    observed.forEach(center.removeObserver)
  }

  private func yield(_ change: Change) {
    let continuation = lock.withLock { self.continuation }
    continuation?.yield(change)
  }
}
