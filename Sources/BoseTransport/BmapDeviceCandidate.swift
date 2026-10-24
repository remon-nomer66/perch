import Foundation
import IOBluetooth

/// One paired device that advertises the BMAP control service, with the link facts the
/// app weighs when several share the audio output's manufacturer block.
///
/// Plain values, read once per scan: correlation is a pure rule over these, so it can be
/// exercised without IOBluetooth. The address is only ever used to open a channel and is
/// never printed.
public struct BmapDeviceCandidate: Equatable, Sendable {
  public let address: String
  /// Whether the Mac has a link to this address right now. Not a requirement: a TWS
  /// earbud's BMAP records can sit on an address other than the one carrying audio, so a
  /// candidate that reports disconnected may still be the one that answers.
  public let isConnected: Bool
  /// When the Mac last accessed this address, as IOBluetooth recorded it, or `nil` when
  /// it has no record.
  public let lastAccess: Date?

  public init(address: String, isConnected: Bool, lastAccess: Date?) {
    self.address = address
    self.isConnected = isConnected
    self.lastAccess = lastAccess
  }
}

/// Every paired device that advertises the BMAP control service, connected ones first
/// and otherwise in IOBluetooth's own order. Selection is by the BMAP marker in cached
/// SDP, *not* by `isConnected()`, for the reason `BmapDeviceCandidate.isConnected` gives.
///
/// Reads cached SDP, so it must be called from a thread with a run loop (the main actor
/// in this app) — a background thread gets empty records back.
public func bmapDeviceCandidates() -> [BmapDeviceCandidate] {
  let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
  let candidates = paired
    .filter { BmapServiceDiscovery.advertisesBmap($0) }
    .compactMap { device -> BmapDeviceCandidate? in
      guard let address = device.addressString else { return nil }
      return BmapDeviceCandidate(
        address: address,
        isConnected: device.isConnected(),
        lastAccess: device.recentAccessDate()
      )
    }
  // Stable-sort connected devices ahead of the rest.
  return candidates.enumerated()
    .sorted { lhs, rhs in
      if lhs.element.isConnected != rhs.element.isConnected {
        return lhs.element.isConnected
      }
      return lhs.offset < rhs.offset
    }
    .map(\.element)
}
