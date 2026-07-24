import BoseCore
import BoseSession
import Foundation
import IOBluetooth

/// Opens Bose BMAP control channels over Classic Bluetooth RFCOMM (SPP), conforming
/// the opened link to `BmapChannel` so `BoseSession` can drive it.
///
/// This is the Bose counterpart to Sony's `RFCOMMChannelHost`. The threading model is
/// the same and for the same reason: every IOBluetooth call and every delegate
/// callback runs on one private thread with its own run loop, because IOBluetooth
/// delivers callbacks to the run loop that opened the channel — a channel opened from
/// a transient context stops receiving the moment that context goes away.
///
/// It is deliberately a separate module from `TandemSession` (see
/// docs/bose-device-contract.md — Sony and Bose share neither UI nor transport code):
/// the two conform to different channel protocols, discover different services, and
/// frame differently. Only the hard-won IOBluetooth plumbing shape is echoed here.
///
/// One difference is load-bearing: the inbound stream is **unbounded**, not
/// `.bufferingNewest`. BMAP has no checksum and no acknowledgement, so a single
/// dropped chunk desynchronises the frame parser permanently (frozen spec §0; handoff
/// H-01 / Codex #7). Dropping the oldest bytes under back-pressure — as the Sony host
/// still does — is therefore not survivable here, so overflow is never silent.

// MARK: - Service discovery

/// Locates the BMAP control service on a paired Bose device via SDP.
///
/// A Bose device advertises the BMAP marker service class
/// `00000000-deca-fade-deca-deafdecacaff`; the actual channel is a standard Serial
/// Port Profile record. The RFCOMM channel number is fully model-dependent (Ultra 2 =
/// 2, QC35 = 8) and must never be baked in, so it is always read from the service
/// record. When SDP cannot answer, discovery fails typed and the caller's retry path
/// decides when to ask again — a guessed channel number can hit an unrelated service.
public enum BmapServiceDiscovery {
  /// The BMAP marker service class. A device advertising it speaks BMAP; QC35
  /// advertises it too, so it identifies the family, never an individual device.
  public static let markerUUID = UUID(uuidString: "00000000-DECA-FADE-DECA-DEAFDECACAFF")!
  /// The standard Serial Port Profile service class the control channel lives on.
  public static let serialPortUUID = UUID(uuidString: "00001101-0000-1000-8000-00805F9B34FB")!

  /// The RFCOMM channel of the BMAP control service on `device`, or `nil` when the
  /// device does not advertise BMAP or no channel can be read.
  ///
  /// The marker only *identifies* a BMAP device; the control channel is read from the
  /// standard SPP (`0x1101`) record, per the frozen spec and confirmed on hardware —
  /// a QC Ultra 2 carries the marker service class on one RFCOMM channel (seen on ch14)
  /// but its actual BMAP control channel is the SPP record's (ch2). Reading the marker
  /// record's own channel opened the wrong endpoint. The SPP channel number is fully
  /// model-dependent (Ultra 2 = 2, QC35 = 8) and never guessed. If the SPP record has no
  /// channel, fall back to the marker record's channel rather than fail outright.
  public static func controlChannel(on device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
    // Must advertise BMAP at all — otherwise it is not a device we speak to.
    guard let markerRecord = serviceRecord(on: device, for: markerUUID) else {
      return nil
    }
    if let sppRecord = serviceRecord(on: device, for: serialPortUUID),
      let channel = channelID(of: sppRecord) {
      return channel
    }
    return channelID(of: markerRecord)
  }

  /// Whether `device` advertises the BMAP marker service class at all. Used to pick a
  /// connected Bose device without opening a channel.
  public static func advertisesBmap(_ device: IOBluetoothDevice) -> Bool {
    serviceRecord(on: device, for: markerUUID) != nil
  }

  private static func serviceRecord(
    on device: IOBluetoothDevice,
    for uuid: UUID
  ) -> IOBluetoothSDPServiceRecord? {
    // `IOBluetoothSDPUUID` takes raw bytes; there is no string initialiser.
    var bytes = uuid.uuid
    let sdpUUID = withUnsafeBytes(of: &bytes) { buffer in
      IOBluetoothSDPUUID(bytes: buffer.baseAddress, length: buffer.count)
    }
    return device.getServiceRecord(for: sdpUUID)
  }

  private static func channelID(of record: IOBluetoothSDPServiceRecord) -> BluetoothRFCOMMChannelID? {
    var discovered: BluetoothRFCOMMChannelID = 0
    guard record.getRFCOMMChannelID(&discovered) == kIOReturnSuccess, discovered != 0 else {
      return nil
    }
    return discovered
  }
}

// MARK: - Failures

/// A failure while opening a BMAP RFCOMM channel. Kept distinct from
/// `BmapChannelFailure` (which is about a channel already open) so a connection
/// problem never looks like a send failure.
public enum BmapChannelOpenFailure: Error, Equatable, Sendable {
  case deviceNotFound
  case deviceNotConnected
  /// The device does not advertise the BMAP service, or its channel could not be read.
  case serviceRecordUnavailable
  case openRejected(Int32)
  case openTimedOut
  case closed
}

// MARK: - Opener

public struct BmapRFCOMMChannelOpener: Sendable {
  public let openTimeout: Duration

  public init(openTimeout: Duration = .seconds(30)) {
    self.openTimeout = openTimeout
  }

  /// Opens the BMAP control channel on the paired device at `address` and returns it
  /// bundled with its inbound byte stream, ready to hand to `BoseSession.start`.
  public func open(address: String) async throws -> OpenedBmapChannel {
    let host = BmapRFCOMMChannelHost(address: address)
    return try await host.open(timeout: openTimeout)
  }
}

/// Finds the address of a connected, paired device that advertises the BMAP control
/// service. Used only to open the channel; the address is never printed, so it stays
/// out of any log.
public func connectedBmapAddress() -> String? {
  let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
  for device in paired where device.isConnected() {
    guard device.addressString != nil else { continue }
    if BmapServiceDiscovery.advertisesBmap(device) {
      return device.addressString
    }
  }
  return nil
}

// MARK: - Host

/// Owns the thread, the run loop, and the channel. Reference semantics and
/// non-`Sendable` IOBluetooth types are confined here; everything the session sees is
/// a value or an actor.
final class BmapRFCOMMChannelHost: NSObject, @unchecked Sendable {
  private let address: String

  private let lock = NSLock()
  private var channel: IOBluetoothRFCOMMChannel?
  private var inboundContinuation: AsyncStream<Data>.Continuation?
  private var openContinuation: CheckedContinuation<Int, Error>?
  private var isClosed = false

  private var thread: Thread?
  private let threadReady = DispatchSemaphore(value: 0)

  init(address: String) {
    self.address = address
    super.init()
  }

  // MARK: - Opening

  func open(timeout: Duration) async throws -> OpenedBmapChannel {
    startThread()

    // Unbounded: a BMAP stream has no checksum, so a dropped chunk corrupts framing
    // for good. Back-pressure must never silently discard bytes here (handoff H-01).
    let (stream, continuation) = AsyncStream<Data>.makeStream(
      bufferingPolicy: .unbounded
    )
    lock.withLock { inboundContinuation = continuation }

    do {
      let mtu = try await withThrowingTaskGroup(of: Int.self) { group in
        group.addTask { try await self.performOpen() }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw BmapChannelOpenFailure.openTimedOut
        }
        guard let first = try await group.next() else { throw BmapChannelOpenFailure.openTimedOut }
        group.cancelAll()
        return first
      }
      _ = mtu  // The send path reads the live MTU per write; nothing needs it here.

      return OpenedBmapChannel(
        channel: BmapRFCOMMChannel(host: self),
        inbound: stream
      )
    } catch {
      // A failed open must leave nothing behind: not a channel a late callback might
      // still deliver, not the inbound stream, and not the thread.
      teardown()
      throw error
    }
  }

  private func performOpen() async throws -> Int {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { openContinuation = continuation }
        guard !Task.isCancelled else {
          finishOpen(.failure(CancellationError()))
          return
        }
        perform { [self] in
          guard lock.withLock({ !isClosed }) else {
            finishOpen(.failure(BmapChannelOpenFailure.closed))
            return
          }
          guard let device = Self.pairedDevice(withAddress: address) else {
            finishOpen(.failure(BmapChannelOpenFailure.deviceNotFound))
            return
          }
          guard device.isConnected() else {
            finishOpen(.failure(BmapChannelOpenFailure.deviceNotConnected))
            return
          }
          // The RFCOMM channel is model-dependent and read from SDP, never guessed.
          guard let channelID = BmapServiceDiscovery.controlChannel(on: device) else {
            finishOpen(.failure(BmapChannelOpenFailure.serviceRecordUnavailable))
            return
          }

          var opened: IOBluetoothRFCOMMChannel?
          let status = device.openRFCOMMChannelAsync(
            &opened,
            withChannelID: channelID,
            delegate: self
          )
          let adopted = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            channel = opened
            return true
          }
          guard adopted else {
            _ = opened?.close()
            return
          }
          if status != kIOReturnSuccess {
            finishOpen(.failure(BmapChannelOpenFailure.openRejected(Int32(status))))
          }
        }
      }
    } onCancel: {
      // The completion callback is not guaranteed to come — on macOS 26 the async open
      // has been seen never calling back — so cancellation (which includes the caller's
      // timeout) must resume the continuation itself or `open` never returns.
      finishOpen(.failure(CancellationError()))
    }
  }

  private func finishOpen(_ result: Result<Int, Error>) {
    let continuation = lock.withLock {
      defer { openContinuation = nil }
      return openContinuation
    }
    continuation?.resume(with: result)
  }

  // MARK: - Writing

  /// One serial queue for every `writeSync`, which blocks its thread until the
  /// baseband takes the bytes. Blocking a cooperative-pool thread starves every other
  /// task sharing it; a private queue spends only its own thread and keeps writes in
  /// submission order.
  private let writeQueue = DispatchQueue(label: "dev.perch.bmap.rfcomm.write")

  func write(_ data: Data) async throws {
    let channel = try lock.withLock { () -> IOBluetoothRFCOMMChannel in
      guard !isClosed, let open = self.channel else { throw BmapChannelFailure.closed }
      return open
    }

    let unchecked = UncheckedSendable(value: channel)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writeQueue.async {
        let channel = unchecked.value
        let limit = Int(channel.getMTU())
        // A BMAP frame must be written whole: splitting it across writes would let an
        // unrelated frame interleave, and with no checksum the corruption is silent.
        guard data.count <= limit, data.count <= Int(UInt16.max) else {
          continuation.resume(
            throwing: BmapChannelFailure.frameExceedsTransmissionUnit(bytes: data.count, limit: limit)
          )
          return
        }

        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { buffer in
          channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        guard status == kIOReturnSuccess else {
          continuation.resume(throwing: BmapChannelFailure.writeRejected)
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  // MARK: - Closing

  func close() {
    teardown()
  }

  /// Releases everything the host owns: the channel, a still-pending open, the inbound
  /// stream, and the thread. Safe to call more than once and from any path.
  private func teardown() {
    let (channel, running) = lock.withLock { () -> (IOBluetoothRFCOMMChannel?, Thread?) in
      defer {
        isClosed = true
        self.channel = nil
        thread = nil
      }
      return (isClosed ? nil : self.channel, thread)
    }

    if let running {
      if let channel {
        run(on: running) { _ = channel.close() }
      }
      run(on: running) { running.cancel() }
    }
    finishOpen(.failure(BmapChannelOpenFailure.closed))
    finishInbound()
  }

  private func finishInbound() {
    let continuation = lock.withLock {
      defer { inboundContinuation = nil }
      return inboundContinuation
    }
    continuation?.finish()
  }

  // MARK: - Thread

  private func startThread() {
    let thread = Thread { [threadReady] in
      // A run loop with no sources returns immediately, so hold one open.
      let source = Port()
      RunLoop.current.add(source, forMode: .default)
      threadReady.signal()
      while !Thread.current.isCancelled {
        RunLoop.current.run(mode: .default, before: .distantFuture)
      }
    }
    thread.name = "dev.perch.bmap.rfcomm"
    thread.qualityOfService = .userInitiated
    thread.start()
    threadReady.wait()
    lock.withLock { self.thread = thread }
  }

  /// Runs on the channel's thread while it exists, inline once it is gone.
  private func perform(_ work: @escaping () -> Void) {
    guard let target = lock.withLock({ thread }) else {
      work()
      return
    }
    run(on: target, work)
  }

  private func run(on target: Thread, _ work: @escaping () -> Void) {
    guard target != Thread.current else {
      work()
      return
    }
    let block = ThreadWork(work)
    block.perform(
      #selector(ThreadWork.run),
      on: target,
      with: nil,
      waitUntilDone: false
    )
  }

  private static func pairedDevice(withAddress address: String) -> IOBluetoothDevice? {
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    return paired.first { device in
      guard let reported = device.addressString else { return false }
      return reported.caseInsensitiveCompare(address) == .orderedSame
    }
  }
}

/// Carries a non-Sendable value across an explicitly serialised hand-off.
private struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
}

/// Carries a closure across `perform(_:on:)`, which needs an Objective-C target.
private final class ThreadWork: NSObject {
  private let work: () -> Void

  init(_ work: @escaping () -> Void) {
    self.work = work
  }

  @objc func run() {
    work()
  }
}

// MARK: - Delegate

extension BmapRFCOMMChannelHost: IOBluetoothRFCOMMChannelDelegate {
  func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    guard error == kIOReturnSuccess else {
      finishOpen(.failure(BmapChannelOpenFailure.openRejected(Int32(error))))
      return
    }
    let alreadyTornDown = lock.withLock { () -> Bool in
      guard !isClosed else { return true }
      channel = rfcommChannel
      return false
    }
    guard !alreadyTornDown else {
      perform { _ = rfcommChannel?.close() }
      return
    }
    finishOpen(.success(Int(rfcommChannel.getMTU())))
  }

  func rfcommChannelData(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!,
    data dataPointer: UnsafeMutableRawPointer!,
    length dataLength: Int
  ) {
    guard dataLength > 0 else { return }
    let data = Data(bytes: dataPointer, count: dataLength)
    let continuation = lock.withLock { inboundContinuation }
    continuation?.yield(data)
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    // A remote close runs the same teardown as a local one.
    teardown()
  }
}

// MARK: - Channel handle

/// The `BmapChannel` the session sends on: encodes each frame to its wire bytes and
/// writes it atomically through the host.
private struct BmapRFCOMMChannel: BmapChannel {
  let host: BmapRFCOMMChannelHost

  func send(_ frame: BmapFrame) async throws {
    try await host.write(frame.encoded())
  }

  func close() async {
    host.close()
  }
}
