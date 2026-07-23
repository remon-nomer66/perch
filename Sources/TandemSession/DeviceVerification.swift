import Foundation
import TandemCore

/// Reads the device's identity and capability inventory, then checks it against the
/// verified profiles.
///
/// Nothing is written here. A device the registry structurally refused never reaches
/// a writable state; only an unknown model or firmware that also passes the
/// experimental gate goes on to the caveated write path, with the caveat on screen
/// (`TandemVerifiedDeviceRegistry.permitsUnverifiedWrites`).
public struct DeviceVerification: DeviceVerifying {
  public init() {}

  public func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    let fingerprint = try await readFingerprint(over: requests)
    do {
      let profile = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
      return .verified(profile, fingerprint)
    } catch let failure as TandemDeviceVerificationFailure {
      return .unsupported(fingerprint, reason: failure)
    }
  }

  public func readFingerprint(
    over requests: SessionRequesting
  ) async throws -> TandemDeviceFingerprint {
    let protocolInfo = try await protocolInfo(over: requests)
    let capability = try await capabilityInfo(over: requests)
    let model = try await deviceInfo(.modelName, over: requests)
    let firmware = try await deviceInfo(.firmwareVersion, over: requests)
    let table1 = try await supportFunctions(TandemFrame.table1DataType, over: requests)
    // The older service generation has no second table and never answers for it, and
    // the session treats an unanswered request as a fault. The dialect is known from
    // the first exchange, so the question is simply never asked of that generation.
    let table2 =
      protocolInfo.dialect == .legacy
      ? []
      : try await supportFunctions(TandemFrame.table2DataType, over: requests)

    return TandemDeviceFingerprint(
      protocolIdentifier: protocolInfo.identifier,
      protocolFirstFlag: protocolInfo.firstFlag,
      protocolSecondFlag: protocolInfo.secondFlag,
      capabilityCode: capability.capabilityCode,
      capabilityIdentifierLength: capability.identifierLength,
      modelName: model,
      firmwareVersion: firmware,
      table1Functions: table1,
      table2Functions: table2,
      dialect: protocolInfo.dialect
    )
  }

  // MARK: - Steps

  private func protocolInfo(over requests: SessionRequesting) async throws -> TandemProtocolInfo {
    let frame = try await requests.request(
      { try TandemReadOnlyHandshake.protocolRequest(sequence: $0) },
      matching: Self.answers(.returnProtocolInfo, on: TandemFrame.table1DataType)
    )
    return try TandemReadOnlyHandshake.parseProtocolResponse(frame)
  }

  private func capabilityInfo(
    over requests: SessionRequesting
  ) async throws -> TandemCapabilityInfo {
    let frame = try await requests.request(
      { try TandemReadOnlyHandshake.capabilityRequest(sequence: $0) },
      matching: Self.answers(.returnCapabilityInfo, on: TandemFrame.table1DataType)
    )
    return try TandemReadOnlyHandshake.parseCapabilityResponse(frame)
  }

  private func deviceInfo(
    _ type: TandemDeviceInfoType,
    over requests: SessionRequesting
  ) async throws -> String {
    let frame = try await requests.request(
      { try TandemReadOnlyHandshake.deviceInfoRequest(type, sequence: $0) },
      // The reply carries the requested field in its second byte. Matching on the
      // command alone would let the model name satisfy a request for the firmware.
      matching: { candidate in
        Self.answers(.returnDeviceInfo, on: TandemFrame.table1DataType)(candidate)
          && candidate.payload.count > 1
          && candidate.payload[candidate.payload.startIndex + 1] == type.rawValue
      }
    )
    return try TandemReadOnlyHandshake.parseDeviceInfoResponse(frame, expectedType: type).value
  }

  private func supportFunctions(
    _ dataType: UInt8,
    over requests: SessionRequesting
  ) async throws -> [TandemSupportFunction] {
    let frame = try await requests.request(
      { try TandemReadOnlyHandshake.supportFunctionRequest(dataType: dataType, sequence: $0) },
      matching: Self.answers(.returnSupportFunction, on: dataType)
    )
    return try TandemReadOnlyHandshake.parseSupportFunctionResponse(frame, expectedDataType: dataType)
  }

  private static func answers(
    _ command: TandemConnectCommand,
    on dataType: UInt8
  ) -> @Sendable (TandemFrame) -> Bool {
    { frame in
      frame.dataType == dataType
        && frame.payload.first == command.rawValue
    }
  }
}
