import BoseCore
import BoseSession
import BoseTransport
import Foundation

/// The Bluetooth edge of the Bose control path: which paired devices speak BMAP, which
/// model one announces, and opening its control channel.
///
/// `BoseDeviceController` decides everything above this — which candidate to try, when
/// to set one aside, what the shared readout says meanwhile. Those decisions are where
/// the bugs were (a readout outliving its device, a silent candidate retried forever),
/// and none of them needs a radio, so the edge is abstracted for them to be exercised
/// without IOBluetooth.
///
/// Main-actor isolated because the live discovery reads IOBluetooth's cached SDP, which
/// is only delivered to a thread with a run loop (see `currentBoseControlAddress`).
@MainActor
protocol BmapDeviceAccess {
  /// Every paired device that advertises BMAP, connected ones first.
  func candidates() -> [BmapDeviceCandidate]
  /// The config for the device at `address`, from the product id it announces.
  func config(forAddress address: String) -> (config: BoseDeviceConfig, productId: UInt16?)
  /// Opens the BMAP control channel on the device at `address`.
  func open(address: String, timeout: Duration) async throws -> OpenedBmapChannel
}

/// The real edge: cached SDP and RFCOMM, through `BoseTransport`.
struct LiveBmapDeviceAccess: BmapDeviceAccess {
  func candidates() -> [BmapDeviceCandidate] {
    bmapDeviceCandidates()
  }

  func config(forAddress address: String) -> (config: BoseDeviceConfig, productId: UInt16?) {
    bmapDeviceConfig(forAddress: address)
  }

  func open(address: String, timeout: Duration) async throws -> OpenedBmapChannel {
    try await BmapRFCOMMChannelOpener(openTimeout: timeout).open(address: address)
  }
}
