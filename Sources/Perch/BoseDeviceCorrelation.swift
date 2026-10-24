import BoseTransport
import Foundation

extension BoseDeviceController {
  /// Picks the BMAP control address belonging to the device currently playing audio.
  ///
  /// A headset's audio address *is* its control address, so an exact match settles it and
  /// nothing below may overrule one. TWS earbuds cannot be settled that way — their audio
  /// rides one address and BMAP another — so correlation falls back to the OUI (the
  /// manufacturer block both share). With a single Bose device paired that is enough.
  ///
  /// With several it names them all, and what orders them from there is provisional: none
  /// of it rests on a measurement of how a TWS product's two addresses relate. In order:
  ///
  /// 1. The longest address prefix shared with the output. *If* a product allocates its
  ///    addresses together they agree past the OUI, where a different Bose product would
  ///    be a 1-in-256 coincidence per octet; if it does not, nothing shares more than the
  ///    OUI and this key decides nothing.
  /// 2. A candidate the Mac has a link to now, over one it has not. A powered-off speaker
  ///    then stops costing a full open timeout before the rotation moves on. It only ranks,
  ///    never filters: a TWS control address can report disconnected while its earbuds
  ///    play, and every device linked to the Mac is "connected", the one in the bag too.
  /// 3. The candidate the Mac accessed most recently; one with no record ranks last.
  /// 4. The scan order.
  ///
  /// What actually stands behind a pick is the rotation (`failedAddresses`): a candidate
  /// that does not answer is set aside and the next one tried. A wrong device that *does*
  /// answer — two Bose devices both linked to the Mac — is caught by neither, which is why
  /// this stays a ranking and not a claim.
  ///
  /// `nonisolated` and pure: the whole rule is exercised without Bluetooth.
  nonisolated static func correlate(output: String, candidates: [BmapDeviceCandidate]) -> String? {
    let outputOctets = addressOctets(of: output)
    guard outputOctets.count >= 3 else { return nil }
    let outputOUI = Array(outputOctets.prefix(3))

    var best: (address: String, affinity: BmapCandidateAffinity)?
    for candidate in candidates {
      let octets = addressOctets(of: candidate.address)
      guard Array(octets.prefix(3)) == outputOUI else { continue }
      // A full match is the device itself; nothing can beat it.
      if octets == outputOctets { return candidate.address }
      let affinity = BmapCandidateAffinity(candidate, octets: octets, output: outputOctets)
      // Strictly greater, so a tie keeps the earlier candidate: the scan order decides last.
      if best.map({ affinity > $0.affinity }) ?? true {
        best = (candidate.address, affinity)
      }
    }
    return best?.address
  }
}

/// How closely a same-maker candidate is tied to the output, compared key by key in the
/// order `BoseDeviceController.correlate(output:candidates:)` gives.
private struct BmapCandidateAffinity: Comparable {
  /// Address octets shared with the output from the start. Three — the OUI — for every
  /// candidate here; more only for an adjacent address.
  let sharedOctets: Int
  let isConnected: Bool
  /// `distantPast` when IOBluetooth recorded no access, so any record outranks none.
  let lastAccess: Date

  init(_ candidate: BmapDeviceCandidate, octets: [String], output: [String]) {
    sharedOctets = zip(octets, output).prefix { $0 == $1 }.count
    isConnected = candidate.isConnected
    lastAccess = candidate.lastAccess ?? .distantPast
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.sharedOctets, lhs.isConnected ? 1 : 0, lhs.lastAccess)
      < (rhs.sharedOctets, rhs.isConnected ? 1 : 0, rhs.lastAccess)
  }
}
