import Foundation
import Testing

@testable import TandemCore

@Test func multipointRequestsUseTable2PeripheralCommands() throws {
  let status = try TandemReadOnlyMultipoint.statusRequest(sequence: 0)
  #expect(status.dataType == TandemFrame.table2DataType)
  #expect(status.payload == Data([0x32, 0x00]))

  let parameters = try TandemReadOnlyMultipoint.parameterRequest(sequence: 1)
  #expect(parameters.dataType == TandemFrame.table2DataType)
  #expect(parameters.payload == Data([0x36, 0x00]))
}

@Test func multipointConnectedDevicesAndActiveSourceAreParsed() throws {
  let statusFrame = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 1,
    payload: Data([0x33, 0x00, 0x00, 0x00])
  )
  let status = try TandemReadOnlyMultipoint.parseStatusResponse(statusFrame)
  #expect(status.mode == .normal)
  #expect(status.isControlEnabled)

  // Synthetic addresses: the locally administered bit (0x02) is set in the first
  // octet, so they cannot collide with any real device.
  var payload = Data([0x37, 0x00, 0x02])
  payload.append(contentsOf: Array("02:00:00:00:00:01".utf8))
  payload.append(0x01)
  payload.append(0x05)
  payload.append(contentsOf: Array("Phone".utf8))
  payload.append(contentsOf: Array("02:00:00:00:00:02".utf8))
  payload.append(0x02)
  payload.append(0x06)
  payload.append(contentsOf: Array("Laptop".utf8))
  payload.append(0x02)

  let parameterFrame = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: payload
  )
  let snapshot = try TandemReadOnlyMultipoint.parseParameterResponse(
    parameterFrame,
    bluetoothMode: status.mode,
    isControlEnabled: status.isControlEnabled
  )

  #expect(snapshot.connectedDevices.map(\.name) == ["Phone", "Laptop"])
  #expect(snapshot.activeConnectionIndex == 2)
  #expect(snapshot.activeDevice?.name == "Laptop")
}

@Test func capturedWF1000XM6ClassOfDeviceMultipointResponseIsParsed() throws {
  let statusFrame = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: Data([0x33, 0x02, 0x00, 0x00])
  )
  let status = try TandemReadOnlyMultipoint.parseStatusResponse(
    statusFrame,
    inquiry: .withBluetoothClassOfDevice
  )

  // The addresses inside the captured payload are synthetic ("02:11:22:33:44:xx",
  // locally administered bit set); only the surrounding structure is as captured.
  let capturedPayload = try dataFromHex(
    "37020430323a31313a32323a33333a34343a3535025a020c0550686f6e65"
      + "30323a31313a32323a33333a34343a363600ffffff065461626c6574"
      + "30323a31313a32323a33333a34343a373700ffffff064c6170746f70"
      + "30323a31313a32323a33333a34343a383800ffffff06506c6179657202"
  )
  let parameterFrame = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 1,
    payload: capturedPayload
  )
  let snapshot = try TandemReadOnlyMultipoint.parseParameterResponse(
    parameterFrame,
    bluetoothMode: status.mode,
    isControlEnabled: status.isControlEnabled,
    inquiry: .withBluetoothClassOfDevice
  )

  #expect(snapshot.devices.count == 4)
  #expect(snapshot.connectedDevices.map(\.name) == ["Phone"])
  #expect(snapshot.activeDevice?.name == "Phone")
  #expect(snapshot.activeDevice?.bluetoothClassOfDevice == 0x5A020C)
}

@Test func anEmptySlotWithAZeroLengthNameIsSkippedNotFatal() throws {
  // Some pairing lists can carry an empty slot — zeroed padding with a zero name
  // length. One such entry must not blank the whole device list on a future
  // model, so it is skipped and the rest is kept.
  var payload = Data([0x37, 0x00, 0x03])
  payload.append(contentsOf: Array("02:00:00:00:00:01".utf8))
  payload.append(0x01)
  payload.append(0x05)
  payload.append(contentsOf: Array("Phone".utf8))
  // The empty slot: a full fixed-size entry of padding, name length zero.
  payload.append(Data(repeating: 0x00, count: 19))
  payload.append(contentsOf: Array("02:00:00:00:00:02".utf8))
  payload.append(0x02)
  payload.append(0x06)
  payload.append(contentsOf: Array("Laptop".utf8))
  payload.append(0x01)

  let frame = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: payload
  )
  let snapshot = try TandemReadOnlyMultipoint.parseParameterResponse(
    frame,
    bluetoothMode: .normal,
    isControlEnabled: true
  )
  #expect(snapshot.devices.map(\.name) == ["Phone", "Laptop"])
  #expect(snapshot.activeDevice?.name == "Phone")
}

@Test func multipointStructuralDamageIsStillRefused() throws {
  func parameterFrame(_ payload: Data) throws -> TandemFrame {
    try TandemFrame(dataType: TandemFrame.table2DataType, sequence: 0, payload: payload)
  }
  func snapshot(_ payload: Data) throws -> TandemMultipointSnapshot {
    try TandemReadOnlyMultipoint.parseParameterResponse(
      try parameterFrame(payload),
      bluetoothMode: .normal,
      isControlEnabled: true
    )
  }

  // An entry cut off inside its fixed part.
  #expect(throws: TandemMultipointError.truncatedDevice(index: 0)) {
    _ = try snapshot(Data([0x37, 0x00, 0x01, 0x41, 0x42]))
  }

  // A name length past the cap: tolerating empty slots must not admit
  // arbitrarily long ones.
  var longName = Data([0x37, 0x00, 0x01])
  longName.append(contentsOf: Array("02:00:00:00:00:01".utf8))
  longName.append(0x01)
  longName.append(0xFF)
  #expect(throws: TandemMultipointError.invalidNameLength(index: 0, length: 255)) {
    _ = try snapshot(longName)
  }

  // A non-empty entry whose address is not an address.
  var badAddress = Data([0x37, 0x00, 0x01])
  badAddress.append(contentsOf: Array("not-an-address-xx".utf8))
  badAddress.append(0x01)
  badAddress.append(0x05)
  badAddress.append(contentsOf: Array("Phone".utf8))
  badAddress.append(0x01)
  #expect(throws: TandemMultipointError.invalidAddress(index: 0)) {
    _ = try snapshot(badAddress)
  }

  // Trailing bytes past the declared entries.
  var trailing = Data([0x37, 0x00, 0x01])
  trailing.append(contentsOf: Array("02:00:00:00:00:01".utf8))
  trailing.append(0x01)
  trailing.append(0x05)
  trailing.append(contentsOf: Array("Phone".utf8))
  trailing.append(contentsOf: [0x01, 0x00])
  #expect(throws: TandemMultipointError.trailingLength(expected: 28, actual: 29)) {
    _ = try snapshot(trailing)
  }

  // A status whose enable byte is neither on nor off.
  let badStatus = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: Data([0x33, 0x00, 0x00, 0x02])
  )
  #expect(throws: TandemMultipointError.invalidEnableDisable(2)) {
    _ = try TandemReadOnlyMultipoint.parseStatusResponse(badStatus)
  }
  // A Bluetooth mode outside the defined values.
  let badMode = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: Data([0x33, 0x00, 0x05, 0x00])
  )
  #expect(throws: TandemMultipointError.invalidBluetoothMode(5)) {
    _ = try TandemReadOnlyMultipoint.parseStatusResponse(badMode)
  }
}

private func dataFromHex(_ hex: String) throws -> Data {
  struct InvalidHex: Error {}
  guard hex.count.isMultiple(of: 2) else { throw InvalidHex() }
  var data = Data()
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    guard let byte = UInt8(hex[index..<next], radix: 16) else { throw InvalidHex() }
    data.append(byte)
    index = next
  }
  return data
}
