import Testing

@testable import TandemSession

private let parser = BluetoothAddressParser()

@Test func addressesAreRecoveredFromTheShapesMacOSHasUsed() {
  // The address is synthetic: the locally administered bit (0x02 in the first
  // octet) is set, so it can never collide with a real device's burned-in address.
  let cases: [(String, String)] = [
    ("02-1A-2B-3C-4D-5E:output", "02:1A:2B:3C:4D:5E"),
    ("02-1A-2B-3C-4D-5E:input", "02:1A:2B:3C:4D:5E"),
    ("02-1A-2B-3C-4D-5E", "02:1A:2B:3C:4D:5E"),
    ("02:1a:2b:3c:4d:5e", "02:1A:2B:3C:4D:5E"),
    ("Sony Headphones (02-1A-2B-3C-4D-5E)", "02:1A:2B:3C:4D:5E"),
  ]

  for (uid, expected) in cases {
    #expect(parser.address(fromDeviceUID: uid)?.rawValue == expected, "failed on \(uid)")
  }
}

@Test func nonBluetoothIdentifiersYieldNothing() {
  // The shapes macOS uses for built-in, HDMI, Continuity, and virtual devices,
  // with synthetic identifiers substituted for the observed ones.
  let cases = [
    "BuiltInSpeakerDevice",
    "BuiltInMicrophoneDevice",
    "MSLoopbackDriverDevice_UID",
    "1A2B3C4D-0000-0000-0000-000000000001",
    "0A0B0C0D-15E0-4AE2-BBD5-D02600000003",
    "",
  ]

  for uid in cases {
    #expect(parser.address(fromDeviceUID: uid) == nil, "\(uid) was mistaken for an address")
  }
}

@Test func mixedSeparatorsAreNotTreatedAsAnAddress() {
  // Accepting these would risk pairing the session with the wrong device.
  #expect(parser.address(fromDeviceUID: "02-1A:2B-3C:4D-5E") == nil)
}

@Test func longerHexRunsAreNotTruncatedIntoAnAddress() {
  // A UUID fragment must not be read as an address by taking the first six pairs.
  #expect(parser.address(fromDeviceUID: "ABCDEF-AB-CD-EF-AB-CD-EF") == nil)
}
