import Foundation
import Testing

@testable import TandemCore

private func fingerprint(
  modelName: String,
  batteryCodes: [UInt8]
) -> TandemDeviceFingerprint {
  TandemDeviceFingerprint(
    protocolIdentifier: 0x0000_0102,
    protocolFirstFlag: 0x01,
    protocolSecondFlag: 0x00,
    capabilityCode: 0x04,
    capabilityIdentifierLength: 6,
    modelName: modelName,
    firmwareVersion: "1.0.0",
    table1Functions: batteryCodes.map { TandemSupportFunction(code: $0, version: 1) },
    table2Functions: []
  )
}

@Test func leftRightBatteriesMeanTheHousingIsSplit() {
  // 完全ワイヤレスは左右それぞれ、多くはケースの残量も申告する。
  let earbuds = fingerprint(modelName: "WF-1000XM6", batteryCodes: [0x21, 0x22])
  #expect(earbuds.housing == .separateLeftRight)
  #expect(earbuds.inferredWearingStyle == .earbuds)
}

@Test func theThresholdVariantsCountAsTheSameEvidence() {
  // 新しい機種は閾値付きの機能コードで同じことを申告する。片方だけ見ていると、
  // まさに新しい機種を取りこぼす。
  let newer = fingerprint(modelName: "WF-1000XM6", batteryCodes: [0x29, 0x2A])
  #expect(newer.housing == .separateLeftRight)

  let single = fingerprint(modelName: "WH-1000XM6", batteryCodes: [0x28])
  #expect(single.housing == .single)
}

@Test func aSingleBatteryMeansOneHousing() {
  let headphone = fingerprint(modelName: "WH-1000XM5", batteryCodes: [0x20])
  #expect(headphone.housing == .single)
  #expect(headphone.inferredWearingStyle == .headband)

  let neckband = fingerprint(modelName: "WI-C100", batteryCodes: [0x20])
  #expect(neckband.housing == .single)
  #expect(neckband.inferredWearingStyle == .neckband)
}

@Test func withoutABatteryDeclarationTheHousingStaysUnknown() {
  // 分からないことを、もっともらしい既定値で埋めない。
  let quiet = fingerprint(modelName: "WH-1000XM5", batteryCodes: [])
  #expect(quiet.housing == .unknown)
}

@Test func theHousingDecidesTheStyleBeforeTheModelNameDoes() {
  // 型番の慣習に従わない機種がある。LinkBuds は完全ワイヤレスだが `WF-` で始まらない。
  // 申告から決まる事実を、名前からの推定に上書きさせない。
  let linkBuds = fingerprint(modelName: "LinkBuds Fit", batteryCodes: [0x21, 0x22])
  #expect(linkBuds.housing == .separateLeftRight)
  #expect(linkBuds.inferredWearingStyle == .earbuds)
}

@Test func anUnfamiliarNameOnOneHousingIsLeftUndecided() {
  // ULT WEAR はヘッドバンド型だが型番が `WH-` ではない。推定できないものを
  // ヘッドバンドと決めつけない。
  let ult = fingerprint(modelName: "ULT WEAR", batteryCodes: [0x20])
  #expect(ult.housing == .single)
  #expect(ult.inferredWearingStyle == .unknown)
}

@Test func aDeviceSuppliedNameIsNormalisedBeforeItIsRead() {
  // 型番は機器が送る文字列で、前後の空白や大小の揺れがありうる。
  let padded = fingerprint(modelName: "  wh-1000xm5\n", batteryCodes: [0x20])
  #expect(padded.inferredWearingStyle == .headband)
}
