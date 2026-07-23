import Testing
@testable import TandemCore

@Test func verifiedWF1000XM6FingerprintIsAccepted() throws {
    let profile = try TandemVerifiedDeviceRegistry.verifiedProfile(
        for: verifiedWF1000XM6Fingerprint()
    )
    #expect(profile.id == "wf-1000xm6-fw-1.5.0-rfcomm-v2")
}

@Test func verifiedWH1000XM6FingerprintIsAccepted() throws {
    let profile = try TandemVerifiedDeviceRegistry.verifiedProfile(
        for: verifiedWH1000XM6Fingerprint()
    )
    #expect(profile.id == "wh-1000xm6-fw-3.1.5-rfcomm-v2")
    // Newer firmware is free to change any wire format while keeping every function
    // code, and with no pinned function versions nothing can vouch that it did not.
    // It is not `verified`; it keeps the caveated unverified path instead.
    let newer = TandemDeviceFingerprint(
        protocolIdentifier: 0x0300_3032,
        protocolFirstFlag: 0,
        protocolSecondFlag: 0,
        capabilityCode: 5,
        capabilityIdentifierLength: 17,
        modelName: "WH-1000XM6",
        firmwareVersion: "3.2.0",
        table1Functions: functions(
            requiredCodes: [0x12, 0x20, 0x57, 0x6D, 0xEB, 0xFC, 0xD1],
            count: 45
        ),
        table2Functions: functions(requiredCodes: [0x33], count: 16)
    )
    #expect(
        throws: TandemDeviceVerificationFailure.unverifiedFirmware(
            model: "WH-1000XM6",
            firmware: "3.2.0"
        )
    ) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: newer)
    }
    #expect(
        TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
            for: newer,
            rejectedWith: .unverifiedFirmware(model: "WH-1000XM6", firmware: "3.2.0")
        )
    )
}

private func verifiedWH1000XM6Fingerprint() -> TandemDeviceFingerprint {
    TandemDeviceFingerprint(
        protocolIdentifier: 0x0300_3032,
        protocolFirstFlag: 0,
        protocolSecondFlag: 0,
        capabilityCode: 5,
        capabilityIdentifierLength: 17,
        modelName: "WH-1000XM6",
        firmwareVersion: "3.1.5",
        table1Functions: functions(
            requiredCodes: [0x12, 0x20, 0x57, 0x6D, 0xEB, 0xFC, 0xD1],
            count: 45
        ),
        table2Functions: functions(requiredCodes: [0x33], count: 16)
    )
}

@Test func anotherSonyModelIsRejectedBeforeControl() {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-1000XM5",
        firmwareVersion: original.firmwareVersion,
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )

    #expect(throws: TandemDeviceVerificationFailure.unverifiedModel("WH-1000XM5")) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
    }
}

@Test func anotherSonyModelCanUseExplicitExperimentalTransportGate() throws {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "0.1.0",
        table1Functions: [TandemSupportFunction(code: 0x57, version: 1)],
        table2Functions: []
    )

    let reference = try TandemVerifiedDeviceRegistry.experimentalReferenceProfile(
        for: fingerprint
    )
    #expect(reference.id == "wf-1000xm6-fw-1.5.0-rfcomm-v2")
}

@Test func experimentalGateRejectsDeviceWithoutKnownControlFunctions() {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "1.0.0",
        table1Functions: [TandemSupportFunction(code: 0x12, version: 1)],
        table2Functions: []
    )

    #expect(throws: TandemDeviceVerificationFailure.noRecognizedControllableFunction) {
        _ = try TandemVerifiedDeviceRegistry.experimentalReferenceProfile(for: fingerprint)
    }
    let assessment = TandemVerifiedDeviceRegistry.experimentalControlAssessment(for: fingerprint)
    #expect(!assessment.isEligible)
    #expect(assessment.recognizedTable1FunctionCodes.isEmpty)
}

@Test func experimentalGateRejectsDuplicateFunctionCodes() {
    let original = verifiedWF1000XM6Fingerprint()
    let duplicate = TandemSupportFunction(code: 0x57, version: 1)
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "1.0.0",
        table1Functions: [duplicate, duplicate],
        table2Functions: []
    )

    #expect(
        throws: TandemDeviceVerificationFailure.duplicateSupportFunction(table: 1, code: 0x57)
    ) {
        _ = try TandemVerifiedDeviceRegistry.experimentalReferenceProfile(for: fingerprint)
    }
}

@Test func experimentalTransportGateStillRejectsAnotherProtocol() {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: 0x0100_0000,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "1.0.0",
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )

    #expect(throws: TandemDeviceVerificationFailure.protocolMismatch(actual: 0x0100_0000)) {
        _ = try TandemVerifiedDeviceRegistry.experimentalReferenceProfile(for: fingerprint)
    }
}

@Test func olderFirmwareIsRejected() {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: "1.4.9",
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )

    #expect(
        throws: TandemDeviceVerificationFailure.unverifiedFirmware(
            model: "WF-1000XM6",
            firmware: "1.4.9"
        )
    ) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
    }
}

@Test func newerFirmwareFallsToTheCaveatPathWithoutPinnedFunctionVersions() {
    // A newer revision keeps its model name and every function code while remaining
    // free to change any wire format. With no pinned function versions there is
    // nothing to vouch that it did not, so it is not `verified` — it keeps the
    // caveated unverified path, where the read-back check is the protection.
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: "1.6.0",
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )

    #expect(
        throws: TandemDeviceVerificationFailure.unverifiedFirmware(
            model: "WF-1000XM6",
            firmware: "1.6.0"
        )
    ) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
    }
    #expect(
        TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
            for: fingerprint,
            rejectedWith: .unverifiedFirmware(model: "WF-1000XM6", firmware: "1.6.0")
        )
    )
}

@Test func newerFirmwareStaysVerifiedOnceControlledVersionsArePinned() throws {
    // Pinned function versions are what detect a wire format change, so once they
    // exist a newer firmware that still reports them may stay verified.
    let base = TandemVerifiedDeviceRegistry.wf1000xm6Firmware150
    let profile = TandemVerifiedDeviceProfile(
        id: base.id,
        modelName: base.modelName,
        firmwareVersion: base.firmwareVersion,
        protocolIdentifier: base.protocolIdentifier,
        protocolFirstFlag: base.protocolFirstFlag,
        protocolSecondFlag: base.protocolSecondFlag,
        capabilityCode: base.capabilityCode,
        capabilityIdentifierLength: base.capabilityIdentifierLength,
        table1FunctionCount: base.table1FunctionCount,
        table2FunctionCount: base.table2FunctionCount,
        requiredTable1FunctionGroups: base.requiredTable1FunctionGroups,
        requiredTable2FunctionGroups: base.requiredTable2FunctionGroups,
        controlledTable1FunctionVersions: [0x57: 1]
    )

    #expect(profile.supportsFirmware("1.6.0"))
    #expect(!base.supportsFirmware("1.6.0"), "nothing is pinned, so nothing can vouch")

    // The pin still rejects a changed wire format on that newer firmware.
    #expect(throws: TandemDeviceVerificationFailure.unverifiedFunctionVersion(
        code: 0x57, expected: 1, actual: 2
    )) {
        try profile.validate(fingerprint(equalizerVersion: 2))
    }
}

@Test func additionalFunctionsAreAcceptedForCompatibleFirmware() throws {
    let original = verifiedWF1000XM6Fingerprint()
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: original.firmwareVersion,
        table1Functions: original.table1Functions
            + [TandemSupportFunction(code: 0xFE, version: 1)],
        table2Functions: original.table2Functions
            + [TandemSupportFunction(code: 0xFE, version: 1)]
    )

    _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
}

@Test func aStructuralRefusalNeverOpensTheCaveatPath() {
    // A known model whose inventory does not match what was verified is a refusal,
    // not an experiment: the caveat path stays closed whatever the gate would say.
    let original = verifiedWF1000XM6Fingerprint()
    let refusals: [TandemDeviceVerificationFailure] = [
        .functionCountMismatch(table: 1, expected: 49, actual: 48),
        .missingRequiredFunction(table: 1, alternatives: [0x57]),
        .duplicateSupportFunction(table: 1, code: 0x57),
        .protocolMismatch(actual: 0x0100_0000),
        .capabilityMismatch(code: 0, identifierLength: 0),
        .unverifiedFunctionVersion(code: 0x57, expected: 1, actual: 2),
        .noRecognizedControllableFunction,
    ]
    for refusal in refusals {
        #expect(
            !TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
                for: original,
                rejectedWith: refusal
            ),
            "\(refusal) opened the caveated write path"
        )
    }
}

@Test func anUnknownModelPassesTheCaveatGateOnlyWhenRecognized() {
    let original = verifiedWF1000XM6Fingerprint()
    // Same conversation shape, unknown name: the experimental case.
    let recognizable = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "1.0.0",
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )
    #expect(
        TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
            for: recognizable,
            rejectedWith: .unverifiedModel("WH-UNKNOWN")
        )
    )

    // An unknown name on an unrecognised conversation stays read-only.
    let unrecognizable = TandemDeviceFingerprint(
        protocolIdentifier: 0x0100_0000,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: "WH-UNKNOWN",
        firmwareVersion: "1.0.0",
        table1Functions: original.table1Functions,
        table2Functions: original.table2Functions
    )
    #expect(
        !TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
            for: unrecognizable,
            rejectedWith: .unverifiedModel("WH-UNKNOWN")
        )
    )
}

@Test func changedCapabilityShapeIsRejected() {
    let original = verifiedWF1000XM6Fingerprint()
    let missingFunction = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: original.firmwareVersion,
        table1Functions: original.table1Functions.filter { $0.code != 0x57 },
        table2Functions: original.table2Functions
    )

    #expect(
        throws: TandemDeviceVerificationFailure.functionCountMismatch(
            table: 1,
            expected: 49,
            actual: 48
        )
    ) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: missingFunction)
    }
}

@Test func missingRequiredFunctionIsRejectedEvenWhenCountMatches() {
    let original = verifiedWF1000XM6Fingerprint()
    let changedFunctions = original.table1Functions.map { function in
        function.code == 0x57
            ? TandemSupportFunction(code: 0xFE, version: function.version)
            : function
    }
    let fingerprint = TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: original.firmwareVersion,
        table1Functions: changedFunctions,
        table2Functions: original.table2Functions
    )

    #expect(
        throws: TandemDeviceVerificationFailure.missingRequiredFunction(
            table: 1,
            alternatives: [0x57]
        )
    ) {
        _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
    }
}

private func verifiedWF1000XM6Fingerprint() -> TandemDeviceFingerprint {
    TandemDeviceFingerprint(
        protocolIdentifier: 0x0300_3002,
        protocolFirstFlag: 0,
        protocolSecondFlag: 0,
        capabilityCode: 6,
        capabilityIdentifierLength: 17,
        modelName: "WF-1000XM6",
        firmwareVersion: "1.5.0",
        table1Functions: functions(
            requiredCodes: [0x12, 0x29, 0x2A, 0x57, 0x6D, 0xEB, 0xFC, 0xD1],
            count: 49
        ),
        table2Functions: functions(requiredCodes: [0x32], count: 16)
    )
}

private func functions(requiredCodes: [UInt8], count: Int) -> [TandemSupportFunction] {
    var codes = requiredCodes
    for candidate in UInt8.min...UInt8.max where codes.count < count {
        if !codes.contains(candidate) {
            codes.append(candidate)
        }
    }
    return codes.map { TandemSupportFunction(code: $0, version: 1) }
}

@Test func firmwareVersionsParseAndCompareNumerically() throws {
  #expect(TandemFirmwareVersion("1.5.0") != nil)
  // A single component, empty components, and non-digits cannot be ordered
  // reliably, so they refuse to parse rather than compare wrongly.
  #expect(TandemFirmwareVersion("1") == nil)
  #expect(TandemFirmwareVersion("1..0") == nil)
  #expect(TandemFirmwareVersion("1.a.0") == nil)
  #expect(TandemFirmwareVersion("") == nil)

  // Numeric, not lexicographic: 1.10.0 is newer than 1.9.9.
  let tenth = try #require(TandemFirmwareVersion("1.10.0"))
  let ninth = try #require(TandemFirmwareVersion("1.9.9"))
  #expect(tenth > ninth)

  // Missing trailing components count as zero.
  let short = try #require(TandemFirmwareVersion("1.5"))
  let long = try #require(TandemFirmwareVersion("1.5.0"))
  #expect(short == long)
  #expect(try #require(TandemFirmwareVersion("1.5.0.1")) > long)

  // An unparseable firmware string can never be vouched for.
  #expect(!TandemVerifiedDeviceRegistry.wf1000xm6Firmware150.supportsFirmware("garbage"))
}

@Test func transportMismatchesAreNamedPrecisely() {
  let original = verifiedWF1000XM6Fingerprint()
  let profile = TandemVerifiedDeviceRegistry.wf1000xm6Firmware150

  let changedFlags = TandemDeviceFingerprint(
    protocolIdentifier: original.protocolIdentifier,
    protocolFirstFlag: 1,
    protocolSecondFlag: original.protocolSecondFlag,
    capabilityCode: original.capabilityCode,
    capabilityIdentifierLength: original.capabilityIdentifierLength,
    modelName: original.modelName,
    firmwareVersion: original.firmwareVersion,
    table1Functions: original.table1Functions,
    table2Functions: original.table2Functions
  )
  #expect(throws: TandemDeviceVerificationFailure.protocolFlagsMismatch(first: 1, second: 0)) {
    try profile.validateTransportCompatibility(changedFlags)
  }

  let changedCapability = TandemDeviceFingerprint(
    protocolIdentifier: original.protocolIdentifier,
    protocolFirstFlag: original.protocolFirstFlag,
    protocolSecondFlag: original.protocolSecondFlag,
    capabilityCode: 9,
    capabilityIdentifierLength: 6,
    modelName: original.modelName,
    firmwareVersion: original.firmwareVersion,
    table1Functions: original.table1Functions,
    table2Functions: original.table2Functions
  )
  #expect(
    throws: TandemDeviceVerificationFailure.capabilityMismatch(code: 9, identifierLength: 6)
  ) {
    try profile.validateTransportCompatibility(changedCapability)
  }
}

@Test func theHeadphoneBatteryGroupStaysExactlyAsObserved() throws {
  // The WH profile requires 0x20 with no 0x28 (with-threshold) alternative, on
  // purpose: the group only ever gates the one observed firmware, which
  // demonstrably declared 0x20 — an alternative nobody observed would loosen
  // that gate. This test pins both halves of that reasoning down.
  let observed = verifiedWH1000XM6Fingerprint()
  let movedBattery = { (firmware: String) -> TandemDeviceFingerprint in
    TandemDeviceFingerprint(
      protocolIdentifier: observed.protocolIdentifier,
      protocolFirstFlag: observed.protocolFirstFlag,
      protocolSecondFlag: observed.protocolSecondFlag,
      capabilityCode: observed.capabilityCode,
      capabilityIdentifierLength: observed.capabilityIdentifierLength,
      modelName: observed.modelName,
      firmwareVersion: firmware,
      table1Functions: observed.table1Functions.map {
        $0.code == 0x20 ? TandemSupportFunction(code: 0x28, version: $0.version) : $0
      },
      table2Functions: observed.table2Functions
    )
  }

  // The verified firmware claiming 0x28 instead of 0x20 is a shape nobody
  // observed: a structural refusal that never opens the caveated write path.
  let sameFirmware = movedBattery("3.1.5")
  #expect(
    throws: TandemDeviceVerificationFailure.missingRequiredFunction(
      table: 1, alternatives: [0x20]
    )
  ) {
    _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: sameFirmware)
  }
  #expect(
    !TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
      for: sameFirmware,
      rejectedWith: .missingRequiredFunction(table: 1, alternatives: [0x20])
    )
  )

  // A newer firmware with the same shape is rejected as unverified before the
  // function groups are even checked, and keeps the caveated path — where
  // battery is read capability-driven, so a 0x28-only device still works there.
  let newerFirmware = movedBattery("3.2.0")
  #expect(
    throws: TandemDeviceVerificationFailure.unverifiedFirmware(
      model: "WH-1000XM6", firmware: "3.2.0"
    )
  ) {
    _ = try TandemVerifiedDeviceRegistry.verifiedProfile(for: newerFirmware)
  }
  #expect(
    TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
      for: newerFirmware,
      rejectedWith: .unverifiedFirmware(model: "WH-1000XM6", firmware: "3.2.0")
    )
  )
}

@Test func aChangedFunctionVersionIsRejectedForControlledFunctions() throws {
  // A firmware may keep a function code while changing that function's wire format,
  // advertising a new version. Matching on the code alone would let the existing
  // encoders write a revision nobody has tested.
  let base = TandemVerifiedDeviceRegistry.wf1000xm6Firmware150
  let equalizer: UInt8 = 0x57
  let profile = TandemVerifiedDeviceProfile(
    id: base.id,
    modelName: base.modelName,
    firmwareVersion: base.firmwareVersion,
    protocolIdentifier: base.protocolIdentifier,
    protocolFirstFlag: base.protocolFirstFlag,
    protocolSecondFlag: base.protocolSecondFlag,
    capabilityCode: base.capabilityCode,
    capabilityIdentifierLength: base.capabilityIdentifierLength,
    table1FunctionCount: base.table1FunctionCount,
    table2FunctionCount: base.table2FunctionCount,
    requiredTable1FunctionGroups: base.requiredTable1FunctionGroups,
    requiredTable2FunctionGroups: base.requiredTable2FunctionGroups,
    controlledTable1FunctionVersions: [equalizer: 1]
  )

  #expect(throws: TandemDeviceVerificationFailure.unverifiedFunctionVersion(
    code: equalizer, expected: 1, actual: 2
  )) {
    try profile.validate(fingerprint(equalizerVersion: 2))
  }

  // The same device reporting the verified version still passes.
  try profile.validate(fingerprint(equalizerVersion: 1))
}

/// The verified fingerprint with the equalizer function reporting a given version.
private func fingerprint(equalizerVersion: UInt8) -> TandemDeviceFingerprint {
    let original = verifiedWF1000XM6Fingerprint()
    let table1 = original.table1Functions.map { function in
        function.code == 0x57
            ? TandemSupportFunction(code: function.code, version: equalizerVersion)
            : function
    }
    return TandemDeviceFingerprint(
        protocolIdentifier: original.protocolIdentifier,
        protocolFirstFlag: original.protocolFirstFlag,
        protocolSecondFlag: original.protocolSecondFlag,
        capabilityCode: original.capabilityCode,
        capabilityIdentifierLength: original.capabilityIdentifierLength,
        modelName: original.modelName,
        firmwareVersion: original.firmwareVersion,
        table1Functions: table1,
        table2Functions: original.table2Functions
    )
}
