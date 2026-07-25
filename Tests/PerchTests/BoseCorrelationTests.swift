import Testing

@testable import Perch

// Addresses here are synthetic: a documentation OUI (00:11:22) and invented low octets,
// never a real unit's address.

@Test func correlationIgnoresDevicesOfAnotherMaker() {
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: ["aa-bb-cc-00-00-01"]
  )
  #expect(chosen == nil)
}

@Test func correlationPrefersTheExactAddress() {
  // Headphones: the audio address *is* the control address, so the exact match must win
  // even though another Bose device sits earlier in the candidate list.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: ["00-11-22-99-99-99", "00-11-22-33-44-55"]
  )
  #expect(chosen == "00-11-22-33-44-55")
}

@Test func correlationMatchesOnOUIWhenNoAddressMatches() {
  // Earbuds: audio rides one address, BMAP another. A single Bose device paired means the
  // OUI alone is unambiguous.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: ["00-11-22-33-44-56"]
  )
  #expect(chosen == "00-11-22-33-44-56")
}

@Test func correlationPicksTheNearestAddressAmongSeveralBoseDevices() {
  // Two Bose devices paired: the earbuds playing audio (…33:44:55) and headphones in the
  // bag (…77:88:99), which happen to come first in the scan. The pair's own control
  // address shares the whole prefix bar the last octet, so it must win.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: ["00-11-22-77-88-99", "00-11-22-33-44-56"]
  )
  #expect(chosen == "00-11-22-33-44-56")
}

@Test func correlationKeepsScanOrderWhenNothingIsNearer() {
  // No candidate shares more than the OUI: the scan order stands, and it puts a currently
  // connected device first.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: ["00-11-22-a0-00-01", "00-11-22-b0-00-02"]
  )
  #expect(chosen == "00-11-22-a0-00-01")
}

@Test func correlationReadsAddressesOutOfCoreAudioDeviceUIDs() {
  // The output identity is a Core Audio UID, not a bare address, and its trailing text
  // must not be read as further octets.
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55:output",
    candidates: ["00:11:22:33:44:55"]
  )
  #expect(chosen == "00:11:22:33:44:55")
}

@Test func correlationRejectsIdentifiersWithoutAnAddress() {
  #expect(BoseDeviceController.correlate(output: "BuiltInSpeakerDevice", candidates: []) == nil)
}

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
  let candidates = ["00-11-22-33-44-56", "00-11-22-33-44-57"]
  let failed = BoseDeviceController.normalized("00-11-22-33-44-56")
  let chosen = BoseDeviceController.correlate(
    output: "00-11-22-33-44-55",
    candidates: candidates.filter { BoseDeviceController.normalized($0) != failed }
  )
  #expect(chosen == "00-11-22-33-44-57")
}
