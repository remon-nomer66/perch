import Foundation

public enum ChannelFailure: Error, Equatable, Sendable {
  case deviceNotFound
  case deviceNotConnected
  /// The device advertises no usable Tandem service record, so there is no channel
  /// number to open. Guessing one would be a model-specific bake-in — the number is
  /// known to differ between models — and could open some unrelated service.
  case serviceRecordUnavailable
  case openRejected(Int32)
  case openTimedOut
  case writeRejected(Int32)
  case frameExceedsTransmissionUnit(bytes: Int, limit: Int)
  case closed
}

/// One open RFCOMM channel.
public protocol TandemChannel: Sendable {
  /// Bytes are delivered whole or not at all: a frame split across two writes would
  /// be interleaved with an acknowledgement and arrive corrupt.
  func write(_ data: Data) async throws
  func close() async
}

/// What an opened channel hands back.
///
/// `inbound` finishing is how a close is reported. Whether that close was asked for
/// is not knowable here, so the coordinator decides by remembering what it requested.
public struct OpenedChannel: Sendable {
  public let channel: any TandemChannel
  public let inbound: AsyncStream<Data>
  public let maximumTransmissionUnit: Int

  public init(
    channel: any TandemChannel,
    inbound: AsyncStream<Data>,
    maximumTransmissionUnit: Int
  ) {
    self.channel = channel
    self.inbound = inbound
    self.maximumTransmissionUnit = maximumTransmissionUnit
  }
}

/// Opens channels. Abstracted so the session can be exercised without hardware.
public protocol TandemChannelOpening: Sendable {
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel
}
