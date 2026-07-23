import Foundation
import Testing

@testable import TandemCore

private func frame(_ payload: [UInt8]) throws -> TandemFrame {
  try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data(payload)
  )
}

@Test func aWrongInquiredTypeOnSupportFunctionsIsNamedAsSuch() throws {
  // This used to be reported as a count mismatch, sending whoever read the
  // diagnostic to the wrong field of the answer.
  let response = try frame([0x07, 0x01, 0x01, 0x11, 0x01])
  #expect(throws: TandemHandshakeError.invalidInquiredType(expected: 0x00, actual: 0x01)) {
    _ = try TandemReadOnlyHandshake.parseSupportFunctionResponse(
      response,
      expectedDataType: TandemFrame.table1DataType
    )
  }
}

@Test func aSupportListMatchingNeitherDialectShapeIsACountError() throws {
  // Three declared functions, but the bytes fit neither the code+version pairs of
  // the current generation nor the bare codes of the older one.
  let response = try frame([0x07, 0x00, 0x03, 0x11, 0x22])
  #expect(throws: TandemHandshakeError.invalidSupportCount(declared: 3, actual: 1)) {
    _ = try TandemReadOnlyHandshake.parseSupportFunctionResponse(
      response,
      expectedDataType: TandemFrame.table1DataType
    )
  }
}

@Test func deviceInfoWithInvalidUTF8IsRefused() throws {
  let response = try frame([0x05, 0x01, 0x02, 0xFF, 0xFE])
  #expect(throws: TandemHandshakeError.invalidDeviceInfoString) {
    _ = try TandemReadOnlyHandshake.parseDeviceInfoResponse(
      response,
      expectedType: .modelName
    )
  }
}

@Test func deviceInfoOfTheWrongTypeIsRefused() throws {
  // A firmware answer must not be accepted where a model name was asked for.
  let response = try frame([0x05, 0x02, 0x03] + Array("1.0".utf8))
  #expect(throws: TandemHandshakeError.invalidDeviceInfoType(0x02)) {
    _ = try TandemReadOnlyHandshake.parseDeviceInfoResponse(
      response,
      expectedType: .modelName
    )
  }
}

@Test func capabilityAnswerWithWrongIdentifierLengthIsRefused() throws {
  let response = try frame([0x03, 0x00, 0x06, 0x05, 0x41, 0x42])
  #expect(
    throws: TandemHandshakeError.invalidCapabilityIdentifierLength(declared: 5, actual: 2)
  ) {
    _ = try TandemReadOnlyHandshake.parseCapabilityResponse(response)
  }
}

@Test func handshakeAnswersOnTheWrongTableAreRefused() throws {
  let table2 = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: Data([0x01, 0x00, 0x02, 0x01])
  )
  #expect(throws: TandemHandshakeError.unexpectedDataType(TandemFrame.table2DataType)) {
    _ = try TandemReadOnlyHandshake.parseProtocolResponse(table2)
  }
}
