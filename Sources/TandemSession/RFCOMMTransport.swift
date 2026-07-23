import Foundation
import IOBluetooth

/// Opens Sony Tandem RFCOMM channels over Classic Bluetooth.
///
/// Every IOBluetooth call and every delegate callback happens on one private thread
/// with its own run loop. IOBluetooth delivers callbacks to the run loop that opened
/// the channel, so a channel opened from a transient context stops receiving data the
/// moment that context goes away.
/// Which of Sony's two service records answered, which also settles the protocol
/// generation.
public enum TandemServiceGeneration: String, Sendable {
  case v2
  case v1

  /// Tried newest first: a device that speaks v2 also advertises v1 on some models.
  static let ordered: [TandemServiceGeneration] = [.v2, .v1]

  var uuid: UUID {
    switch self {
    case .v2: UUID(uuidString: "956C7B26-D49A-4BA8-B03F-B17D393CB6E2")!
    case .v1: UUID(uuidString: "96CC203E-5068-46AD-B32D-E316F5E069BA")!
    }
  }
}

extension TandemServiceGeneration {
  /// Which generation a paired device advertises, and on which channel.
  ///
  /// Exposed so a diagnostic can report it without opening a channel.
  public static func discover(
    address: String
  ) -> (generation: TandemServiceGeneration, channel: BluetoothRFCOMMChannelID)? {
    let wanted = DeviceIdentity(address)
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    guard
      let device = paired.first(where: {
        guard let reported = $0.addressString else { return false }
        return DeviceIdentity(reported) == wanted
      })
    else {
      return nil
    }
    return RFCOMMChannelHost.serviceRecord(on: device)
  }
}

public struct RFCOMMChannelOpener: TandemChannelOpening {
  public let openTimeout: Duration

  public init(openTimeout: Duration = .seconds(30)) {
    self.openTimeout = openTimeout
  }

  public func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    let host = RFCOMMChannelHost(address: device.rawValue)
    return try await host.open(timeout: openTimeout)
  }
}

/// Owns the thread, the run loop, and the channel. Reference semantics and
/// non-`Sendable` IOBluetooth types are confined here; everything the rest of the
/// session sees is either a value or an actor.
final class RFCOMMChannelHost: NSObject, @unchecked Sendable {
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

  func open(timeout: Duration) async throws -> OpenedChannel {
    startThread()

    let (stream, continuation) = AsyncStream<Data>.makeStream(
      bufferingPolicy: .bufferingNewest(RFCOMMChannelHost.inboundBufferLimit)
    )
    lock.withLock { inboundContinuation = continuation }

    do {
      let mtu = try await withThrowingTaskGroup(of: Int.self) { group in
        group.addTask { try await self.performOpen() }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw ChannelFailure.openTimedOut
        }
        guard let first = try await group.next() else { throw ChannelFailure.openTimedOut }
        group.cancelAll()
        return first
      }

      return OpenedChannel(
        channel: RFCOMMChannel(host: self),
        inbound: stream,
        maximumTransmissionUnit: mtu
      )
    } catch {
      // A failed open must leave nothing behind: not a channel a late callback
      // might still deliver, not the inbound stream, and not the thread. Without
      // this, every refused or timed-out open leaked one thread.
      teardown()
      throw error
    }
  }

  private func performOpen() async throws -> Int {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { openContinuation = continuation }
        // Cancellation may have landed before the continuation was stored, in
        // which case the handler below found nothing to resume. Checking after
        // the store closes that window; `finishOpen` resumes at most once.
        guard !Task.isCancelled else {
          finishOpen(.failure(CancellationError()))
          return
        }
        perform { [self] in
          // The block can be processed after a teardown that raced the open. There
          // is nobody left to adopt a channel then, so don't start one.
          guard lock.withLock({ !isClosed }) else {
            finishOpen(.failure(ChannelFailure.closed))
            return
          }
          guard let device = Self.pairedDevice(withAddress: address) else {
            finishOpen(.failure(ChannelFailure.deviceNotFound))
            return
          }
          guard device.isConnected() else {
            finishOpen(.failure(ChannelFailure.deviceNotConnected))
            return
          }

          // The channel number is not the same on every model: v1 devices have been
          // seen on 15 where v2 devices use 9. Reading it from the service record
          // removes the guess, and tells us which protocol generation answered.
          // When the record cannot be read there is nothing safe to open — a guessed
          // number is a model-specific bake-in and can hit an unrelated service —
          // so the open fails typed and the session's retry path decides when to
          // ask again.
          guard let discovered = Self.serviceRecord(on: device) else {
            finishOpen(.failure(ChannelFailure.serviceRecordUnavailable))
            return
          }
          let channelID = discovered.channel

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
            // A teardown landed while the open call was in flight; the teardown
            // saw no channel, so this half-open one is closed here instead.
            _ = opened?.close()
            return
          }
          if status != kIOReturnSuccess {
            finishOpen(.failure(ChannelFailure.openRejected(Int32(status))))
          }
        }
      }
    } onCancel: {
      // The completion callback is not guaranteed to come — on macOS 26 the async
      // open has been observed never calling back — so cancellation, which includes
      // the caller's timeout, must resume the continuation itself or `open` never
      // returns.
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
  /// baseband takes the bytes. Blocking a cooperative-pool thread there — the actor
  /// callers run on the pool — starves every other task sharing it; a private queue
  /// spends only its own thread and keeps writes in submission order. The channel's
  /// run-loop thread is deliberately not used: parking a blocking call on the same
  /// thread that delivers the delegate callbacks would delay inbound data behind
  /// each write.
  private let writeQueue = DispatchQueue(label: "dev.perch.rfcomm.write")

  func write(_ data: Data) async throws {
    let channel = try lock.withLock { () -> IOBluetoothRFCOMMChannel in
      guard !isClosed, let open = self.channel else { throw ChannelFailure.closed }
      return open
    }

    // The channel is not Sendable; handing it to the queue is safe because
    // IOBluetooth channel calls are not confined to the opening thread — only the
    // delegate callbacks are — and this host already called it from arbitrary
    // cooperative threads before the queue existed.
    let unchecked = UncheckedSendable(value: channel)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writeQueue.async {
        let channel = unchecked.value
        let limit = Int(channel.getMTU())
        // Splitting a frame across writes would let an acknowledgement land in the
        // middle of it, so an oversized frame is refused rather than fragmented.
        guard data.count <= limit, data.count <= Int(UInt16.max) else {
          continuation.resume(
            throwing: ChannelFailure.frameExceedsTransmissionUnit(bytes: data.count, limit: limit)
          )
          return
        }

        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { buffer in
          channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        guard status == kIOReturnSuccess else {
          continuation.resume(throwing: ChannelFailure.writeRejected(Int32(status)))
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

  /// Releases everything the host owns: the channel, a still-pending open, the
  /// inbound stream, and the thread. Safe to call more than once and from any path —
  /// a failed open, a caller's close, and a remote close all end here — because the
  /// state is taken under the lock exactly once.
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
      // Both blocks run on the channel's thread, in order: the close first, then
      // the cancel that lets the run loop wind down. Cancelling any other way can
      // miss a parked run loop — the flag alone never wakes it — or race the
      // thread's exit; a posted cancel is its own wake-up, and the thread cannot
      // exit before it runs because only this block sets the flag.
      if let channel {
        run(on: running) { _ = channel.close() }
      }
      run(on: running) { running.cancel() }
    }
    // An open still in flight has to be failed, or its caller waits forever.
    finishOpen(.failure(ChannelFailure.closed))
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
    thread.name = "dev.perch.rfcomm"
    thread.qualityOfService = .userInitiated
    thread.start()
    threadReady.wait()
    lock.withLock { self.thread = thread }
  }

  /// Runs on the channel's thread while it exists, inline once it is gone. The
  /// inline fallback keeps late work — a close racing a teardown — off a thread
  /// handle that may already have exited, which `perform(_:on:)` would trap on.
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
    // Not `BlockOperation`: its initialiser demands a `Sendable` closure, and the
    // work here holds IOBluetooth objects, which are not. The hand-off is still
    // safe — the block is built here and only ever run on the target thread.
    let block = ThreadWork(work)
    block.perform(
      #selector(ThreadWork.run),
      on: target,
      with: nil,
      waitUntilDone: false
    )
  }

  /// Asks the device which channel carries Sony's control service.
  static func serviceRecord(
    on device: IOBluetoothDevice
  ) -> (generation: TandemServiceGeneration, channel: BluetoothRFCOMMChannelID)? {
    for generation in TandemServiceGeneration.ordered {
      // `IOBluetoothSDPUUID` takes raw bytes; there is no string initialiser.
      var bytes = generation.uuid.uuid
      let uuid = withUnsafeBytes(of: &bytes) { buffer in
        IOBluetoothSDPUUID(bytes: buffer.baseAddress, length: buffer.count)
      }
      guard let record = device.getServiceRecord(for: uuid) else { continue }
      var discovered: BluetoothRFCOMMChannelID = 0
      guard record.getRFCOMMChannelID(&discovered) == kIOReturnSuccess, discovered != 0 else {
        continue
      }
      return (generation, discovered)
    }
    return nil
  }

  private static func pairedDevice(withAddress address: String) -> IOBluetoothDevice? {
    let wanted = DeviceIdentity(address)
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    return paired.first { device in
      guard let reported = device.addressString else { return false }
      return DeviceIdentity(reported) == wanted
    }
  }

  /// Enough room for a burst of notifications while a request is being handled.
  /// Beyond this the session is failing anyway, and dropping the oldest bytes would
  /// silently corrupt a frame.
  private static let inboundBufferLimit = 256
}

/// Carries a non-Sendable value across an explicitly serialised hand-off. Used only
/// where the receiving side is the sole concurrent user of the value.
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

extension RFCOMMChannelHost: IOBluetoothRFCOMMChannelDelegate {
  func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    guard error == kIOReturnSuccess else {
      finishOpen(.failure(ChannelFailure.openRejected(Int32(error))))
      return
    }
    let alreadyTornDown = lock.withLock { () -> Bool in
      guard !isClosed else { return true }
      channel = rfcommChannel
      return false
    }
    guard !alreadyTornDown else {
      // The open raced a teardown — the caller timed out or cancelled — so nobody
      // is left to use the channel. Adopting it here would leave it open forever.
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
    // A remote close runs the same teardown as a local one. Merely marking the host
    // closed here left the thread behind: the later local `close()` found `isClosed`
    // already set and returned, leaking one thread per remote disconnect.
    teardown()
  }
}

// MARK: - Channel handle

private struct RFCOMMChannel: TandemChannel {
  let host: RFCOMMChannelHost

  func write(_ data: Data) async throws {
    try await host.write(data)
  }

  func close() async {
    host.close()
  }
}
