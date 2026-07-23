import Foundation
import Testing
@testable import TandemCore

@Test func protocolRequestMatchesCapturedWireFormat() throws {
    let frame = try TandemReadOnlyHandshake.protocolRequest(sequence: 0)
    #expect(frame.encoded() == Data([0x3E, 0x0C, 0x00, 0, 0, 0, 2, 0, 0, 0x0E, 0x3C]))
}

@Test func acknowledgementMatchesStaticEncoder() throws {
    let ackForZero = try TandemFrame.acknowledgement(for: 0)
    let ackForOne = try TandemFrame.acknowledgement(for: 1)
    #expect(ackForZero.encoded() == Data([0x3E, 1, 1, 0, 0, 0, 0, 2, 0x3C]))
    #expect(ackForOne.encoded() == Data([0x3E, 1, 0, 0, 0, 0, 0, 1, 0x3C]))
}

@Test func reservedBytesAreEscapedAndDecodedAcrossChunks() throws {
    let original = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data([0x3C, 0x3D, 0x3E])
    )
    let encoded = original.encoded()
    #expect(encoded.contains(Data([0x3D, 0x2C])))
    #expect(encoded.contains(Data([0x3D, 0x2D])))
    #expect(encoded.contains(Data([0x3D, 0x2E])))

    var decoder = TandemStreamDecoder()
    var decoded: [TandemFrame] = []
    for byte in encoded {
        decoded.append(contentsOf: try decoder.append(Data([byte])))
    }
    #expect(decoded == [original])
}

@Test func capturedProtocolResponseIsParsed() throws {
    let response = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data([0x01, 0x00, 0x03, 0x00, 0x30, 0x02, 0x00, 0x00])
    )
    let info = try TandemReadOnlyHandshake.parseProtocolResponse(response)
    #expect(info.identifier == 0x03003002)
    #expect(info.firstFlag == 0)
    #expect(info.secondFlag == 0)
}

// The older service generation answers with a two-byte version and no flags — a
// captured WF-1000XM3 reply. Rejecting it is what kept that generation stuck at
// "reading the device".
@Test func shortProtocolResponseOfTheOlderGenerationIsParsed() throws {
    let response = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data([0x01, 0x00, 0x02, 0x01])
    )
    let info = try TandemReadOnlyHandshake.parseProtocolResponse(response)
    #expect(info.identifier == 0x0201)
    #expect(info.firstFlag == 0)
    #expect(info.secondFlag == 0)
}

// The older generation lists one byte per function — the code alone, no version — a
// captured WF-1000XM3 reply shape. The current generation lists code and version pairs.
@Test func supportFunctionsOfTheOlderGenerationAreParsedWithoutVersions() throws {
    let response = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 0,
        payload: Data([0x07, 0x00, 0x03, 0x11, 0x22, 0x33])
    )
    let functions = try TandemReadOnlyHandshake.parseSupportFunctionResponse(
        response,
        expectedDataType: TandemFrame.table1DataType
    )
    #expect(functions == [
        TandemSupportFunction(code: 0x11, version: 0),
        TandemSupportFunction(code: 0x22, version: 0),
        TandemSupportFunction(code: 0x33, version: 0),
    ])
}

@Test func protocolResponseOfUnknownLengthIsRejected() throws {
    let response = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data([0x01, 0x00, 0x02, 0x01, 0x00])
    )
    #expect(throws: TandemHandshakeError.invalidProtocolPayloadLength(5)) {
        try TandemReadOnlyHandshake.parseProtocolResponse(response)
    }
}

@Test func capabilityIdentifierIsNotRetained() throws {
    // Synthetic MAC-format identifier: the locally administered bit (0x02) is set
    // in the first octet, so it cannot collide with any real device.
    let identifier = Array("02:00:00:00:00:01".utf8)
    let response = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 0,
        payload: Data([0x03, 0x00, 0x06, UInt8(identifier.count)] + identifier)
    )
    let info = try TandemReadOnlyHandshake.parseCapabilityResponse(response)
    #expect(info.capabilityCode == 6)
    #expect(info.identifierLength == 17)
}

@Test func checksumFailureIsRejected() throws {
    var wire = [UInt8](try TandemReadOnlyHandshake.protocolRequest(sequence: 0).encoded())
    wire[wire.count - 2] ^= 0x01
    var decoder = TandemStreamDecoder()
    #expect(throws: TandemFrameError.self) {
        _ = try decoder.append(Data(wire))
    }
}

@Test func deviceInfoAndSupportFunctionsAreParsed() throws {
    let modelName = Array("WF-1000XM6".utf8)
    let model = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 0,
        payload: Data([0x05, 0x01, UInt8(modelName.count)] + modelName)
    )
    let parsedModel = try TandemReadOnlyHandshake.parseDeviceInfoResponse(
        model,
        expectedType: .modelName
    )
    #expect(parsedModel.value == "WF-1000XM6")

    let support = try TandemFrame(
        dataType: TandemFrame.table2DataType,
        sequence: 1,
        payload: Data([0x07, 0x00, 0x02, 0x01, 0x03, 0x05, 0x02])
    )
    let functions = try TandemReadOnlyHandshake.parseSupportFunctionResponse(
        support,
        expectedDataType: TandemFrame.table2DataType
    )
    #expect(functions == [
        TandemSupportFunction(code: 0x01, version: 0x03),
        TandemSupportFunction(code: 0x05, version: 0x02)
    ])
}

@Test func codecAndBatteryStatusAreParsed() throws {
    let codecFrame = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 0,
        payload: Data([0x13, 0x02, 0x10])
    )
    #expect(try TandemReadOnlyStatus.parseAudioCodecResponse(codecFrame) == .ldac)

    let earbudsFrame = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data([0x23, 0x09, 54, 0, 59, 0, 100, 100])
    )
    let earbuds = try TandemReadOnlyStatus.parseEarbudBatteryResponse(earbudsFrame)
    #expect(earbuds.leftPercent == 54)
    #expect(earbuds.rightPercent == 59)
    #expect(earbuds.leftChargingStatus == .notCharging)

    let caseFrame = try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 0,
        payload: Data([0x23, 0x0A, 44, 0, 30])
    )
    let chargingCase = try TandemReadOnlyStatus.parseCaseBatteryResponse(caseFrame)
    #expect(chargingCase.percent == 44)
    #expect(chargingCase.threshold == 30)

    let generic = try TandemReadOnlyStatus.parseBatteryResponse(
        earbudsFrame,
        query: .leftRightWithThreshold
    )
    #expect(generic.units.map(\.percent) == [54, 59])
    #expect(generic.units.map(\.threshold) == [100, 100])
}
