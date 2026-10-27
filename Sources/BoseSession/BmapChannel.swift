import BoseCore
import Foundation

/// A failure while sending on or holding a BMAP transport.
///
/// Deliberately transport-neutral: the RFCOMM and BLE transports added in stage 5
/// map their own IOBluetooth / CoreBluetooth errors onto these cases, so the session
/// never sees a framework-specific error type. A BMAP `ERROR` frame is *not* one of
/// these — it means the link is working and the device answered, so it surfaces as a
/// `BoseRequestError.device`, never as a channel failure.
public enum BmapChannelFailure: Error, Equatable, Sendable {
  case notConnected
  case writeRejected
  case closed
  /// The encoded frame is larger than the transport's write unit. BLE's 20-byte
  /// segmentation is handled below this layer, so this is a genuine over-limit write.
  case frameExceedsTransmissionUnit(bytes: Int, limit: Int)
}

/// One open BMAP transport the session sends frames on.
///
/// The receive side is delivered separately as an `AsyncStream<Data>` (see
/// `OpenedBmapChannel`) that the session drains continuously and feeds through a
/// `BmapStreamParser`. Keeping receive out of the protocol lets the transport hand
/// back raw bytes without knowing about framing, and lets the session own the single
/// parser instance whose state must survive across chunks.
public protocol BmapChannel: Sendable {
  /// Sends one whole frame. The frame is encoded to its wire bytes by the session, so
  /// a conformer only has to move the bytes; it must write them atomically, since a
  /// frame split across two writes and interleaved with an unrelated one would arrive
  /// unparseable (BMAP has no checksum to notice the corruption).
  func send(_ frame: BmapFrame) async throws
  func close() async
}

/// A transport bundled with its inbound byte stream.
///
/// `inbound` finishing is how a remote close is reported: the session's drain loop
/// ends, which tears the session down. Whether that close was asked for is decided by
/// the session, which remembers whether it called `close()`.
public struct OpenedBmapChannel: Sendable {
  public let channel: any BmapChannel
  public let inbound: AsyncStream<Data>

  public init(channel: any BmapChannel, inbound: AsyncStream<Data>) {
    self.channel = channel
    self.inbound = inbound
  }
}
