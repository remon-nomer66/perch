import BoseTransport
import Foundation
import Testing

@testable import Perch

// Addresses here are synthetic: a documentation OUI (00:11:22) and invented low octets,
// never a real unit's address.

/// Candidates as a scan would list them, with no link facts to rank them by.
private func scanned(_ addresses: String...) -> [BmapDeviceCandidate] {
  addresses.map { candidate($0) }
}

@Test func correlationIgnoresDevicesOfAnotherMaker() {
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: scanned("aa-bb-cc-00-00-01")
  )
  #expect(chosen == nil)
}

@Test func correlationPrefersTheExactAddress() {
  // Headphones: the audio address *is* the control address, so the exact match must win
  // even though another Bose device sits earlier in the candidate list.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: scanned("00-11-22-99-99-99", "00-11-22-33-44-55")
  )
  #expect(chosen == "00-11-22-33-44-55")
}

@Test func correlationMatchesOnOUIWhenNoAddressMatches() {
  // Earbuds: audio rides one address, BMAP another. A single Bose device paired means the
  // OUI alone is unambiguous.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: scanned("00-11-22-33-44-56")
  )
  #expect(chosen == "00-11-22-33-44-56")
}

@Test func correlationPicksTheNearestAddressAmongSeveralBoseDevices() {
  // Two Bose devices paired: the earbuds playing audio (…33:44:55) and headphones in the
  // bag (…77:88:99), which happen to come first in the scan. A candidate sharing the
  // output's address past the OUI wins.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: scanned("00-11-22-77-88-99", "00-11-22-33-44-56")
  )
  #expect(chosen == "00-11-22-33-44-56")
}

@Test func correlationKeepsScanOrderWhenNothingIsNearer() {
  // No candidate shares more than the OUI and none has a link fact to go on: the scan
  // order stands.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: scanned("00-11-22-a0-00-01", "00-11-22-b0-00-02")
  )
  #expect(chosen == "00-11-22-a0-00-01")
}

@Test func correlationReadsAddressesOutOfCoreAudioDeviceUIDs() {
  // The output identity is a Core Audio UID, not a bare address, and its trailing text
  // must not be read as further octets.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55:output",
    candidates: scanned("00:11:22:33:44:55")
  )
  #expect(chosen == "00:11:22:33:44:55")
}

@Test func correlationRejectsIdentifiersWithoutAnAddress() {
  #expect(BoseDeviceController.correlate(output: "BuiltInSpeakerDevice", candidates: []) == nil)
}

// MARK: - Link facts

/// Several Bose devices share the OUI and none is nearer the output. One the Mac has a
/// link to now beats one it does not — the powered-off speaker that sat first in the scan
/// cost a full open timeout before the rotation moved on.
@Test func correlationPrefersAConnectedCandidateWhenNothingIsNearer() {
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [
      candidate("00-11-22-a0-00-01"),
      candidate("00-11-22-b0-00-02", connected: true),
    ]
  )
  #expect(chosen == "00-11-22-b0-00-02")
}

/// With the connection state alike, the candidate the Mac accessed most recently wins; one
/// with no recorded access ranks below any that has one.
@Test func correlationPrefersTheMostRecentlyAccessedCandidate() {
  let earlier = Date(timeIntervalSinceReferenceDate: 1_000)
  let later = Date(timeIntervalSinceReferenceDate: 2_000)
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [
      candidate("00-11-22-a0-00-01"),
      candidate("00-11-22-b0-00-02", lastAccess: earlier),
      candidate("00-11-22-c0-00-03", lastAccess: later),
    ]
  )
  #expect(chosen == "00-11-22-c0-00-03")
}

/// Connection outranks recency: a link now says more than a link once.
@Test func correlationRanksConnectionAboveRecency() {
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [
      candidate("00-11-22-a0-00-01", lastAccess: Date(timeIntervalSinceReferenceDate: 9_000)),
      candidate("00-11-22-b0-00-02", connected: true, lastAccess: nil),
    ]
  )
  #expect(chosen == "00-11-22-b0-00-02")
}

/// The link facts only order candidates that are otherwise alike. They never overrule the
/// exact address, and never a candidate that agrees with the output past the OUI — two
/// different products sharing a fourth octet is a 1-in-256 coincidence, while "connected"
/// is true of every device the Mac is linked to, the one in the bag included.
@Test func linkFactsNeverOverruleTheAddress() {
  let exact = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [
      candidate("00-11-22-a0-00-01", connected: true, lastAccess: .distantFuture),
      candidate("00-11-22-33-44-55"),
    ]
  )
  #expect(exact == "00-11-22-33-44-55")

  let near = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [
      candidate("00-11-22-a0-00-01", connected: true, lastAccess: .distantFuture),
      candidate("00-11-22-33-44-56"),
    ]
  )
  #expect(near == "00-11-22-33-44-56")
}

/// A candidate of another maker stays out however connected it is.
@Test func linkFactsNeverAdmitAnotherMaker() {
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: [candidate("aa-bb-cc-00-00-01", connected: true, lastAccess: .distantFuture)]
  )
  #expect(chosen == nil)
}

// MARK: - Normalisation

/// The same device however IOBluetooth or Core Audio spelled it, so an address set aside
/// after a failed open is recognised again on the next pass.
@Test func addressesNormalizeToOneForm() {
  #expect(BoseDeviceController.normalized("00-11-22-33-44-55") == "00:11:22:33:44:55")
  #expect(BoseDeviceController.normalized("00:11:22:33:44:55") == "00:11:22:33:44:55")
  #expect(BoseDeviceController.normalized("00-11-22-AB-CD-EF") == "00:11:22:ab:cd:ef")
  #expect(BoseDeviceController.normalized("00-11-22-33-44-55:output") == "00:11:22:33:44:55")
}

/// A paired Bose product can publish two BMAP addresses where only one answers (seen on
/// QC Ultra Earbuds: the first candidate timed out, the second connected). Excluding the
/// one that failed must hand back the other rather than nothing.
@Test func correlationPicksTheRemainingCandidateWhenOneIsExcluded() {
  let candidates = scanned("00-11-22-33-44-56", "00-11-22-33-44-57")
  let failed = BoseDeviceController.normalized("00-11-22-33-44-56")
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: candidates.filter { BoseDeviceController.normalized($0.address) != failed }
  )
  #expect(chosen == "00-11-22-33-44-57")
}
