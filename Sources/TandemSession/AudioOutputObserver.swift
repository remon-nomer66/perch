import CoreAudio
import Foundation

/// Which device is currently receiving audio, and whether we can identify it.
public enum AudioOutput: Equatable, Sendable {
  /// A Bluetooth output whose address we recovered.
  case identified(DeviceIdentity)
  /// A Bluetooth output we could not identify. The user has to say which device it
  /// is; guessing risks writing settings to the wrong headphones.
  case unidentifiedBluetooth(uid: String)
  /// Anything else: speakers, HDMI, a virtual device.
  case other
}

/// What the session needs to know about the default audio output. Abstracted so the
/// event translation in `SessionService` can be exercised without Core Audio.
public protocol AudioOutputObserving: Sendable {
  var changes: AsyncStream<AudioOutput> { get }
  func start()
  func stop()
  /// The output right now, asked when a stored value cannot be trusted (waking).
  func current() -> AudioOutput
}

/// Reports changes to the default audio output.
///
/// Core Audio delivers its notifications on an internal queue, so the values are
/// republished on a stream the session can await.
public final class AudioOutputObserver: AudioOutputObserving, @unchecked Sendable {
  private let parser: BluetoothAddressParser
  private let lock = NSLock()
  private var continuation: AsyncStream<AudioOutput>.Continuation?
  private var listener: AudioObjectPropertyListenerBlock?

  public init(parser: BluetoothAddressParser = BluetoothAddressParser()) {
    self.parser = parser
  }

  public private(set) lazy var changes: AsyncStream<AudioOutput> = {
    let (stream, continuation) = AsyncStream<AudioOutput>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    lock.withLock { self.continuation = continuation }
    return stream
  }()

  public func start() {
    var address = Self.defaultOutputAddress()
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      let continuation = lock.withLock { self.continuation }
      continuation?.yield(current())
    }
    lock.withLock { self.listener = listener }

    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      nil,
      listener
    )
    // Publish the state at start-up: the first notification only arrives when
    // something changes, which may be long after launch.
    let continuation = lock.withLock { self.continuation }
    continuation?.yield(current())
  }

  public func stop() {
    guard let listener = lock.withLock({ self.listener }) else { return }
    var address = Self.defaultOutputAddress()
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      nil,
      listener
    )
    lock.withLock { self.listener = nil }
  }

  public func current() -> AudioOutput {
    guard let device = Self.defaultOutputDevice() else { return .other }
    guard Self.transportType(of: device) == kAudioDeviceTransportTypeBluetooth else {
      return .other
    }
    guard let uid = Self.stringProperty(device, kAudioDevicePropertyDeviceUID) else {
      return .other
    }
    guard let identity = parser.address(fromDeviceUID: uid) else {
      return .unidentifiedBluetooth(uid: uid)
    }
    return .identified(identity)
  }

  // MARK: - Core Audio

  private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func defaultOutputDevice() -> AudioObjectID? {
    var address = defaultOutputAddress()
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    )
    return status == noErr && device != 0 ? device : nil
  }

  private static func transportType(of device: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
  }

  private static func stringProperty(
    _ device: AudioObjectID,
    _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}
