import Foundation
import Testing

@testable import TandemCore

@Test func listeningFeaturesFollowDeclaredFunctionsOnly() {
  #expect(TandemListeningCatalog.features(forDeclared: []).isEmpty)

  let both = TandemListeningCatalog.features(forDeclared: [0xEB, 0xE5])
  #expect(both.map(\.kind) == [.backgroundMusic, .cinema])
  #expect(both.first { $0.kind == .backgroundMusic }?.inquiry == 0x09)
  #expect(both.first { $0.kind == .cinema }?.inquiry == 0x04)

  // A model that only declares cinema gets cinema and no background music.
  let cinemaOnly = TandemListeningCatalog.features(forDeclared: [0xE5])
  #expect(cinemaOnly.map(\.kind) == [.cinema])

  // The richer background-music variant wins when both are declared.
  let bgm = TandemListeningCatalog.features(forDeclared: [0xE4, 0xEB])
  #expect(bgm.count == 1)
  #expect(bgm.first?.inquiry == 0x09)
}

@Test func backgroundMusicRequestsMatchCapturedProtocol() throws {
  let feature = TandemListeningFeature(function: 0xEB, inquiry: 0x09, kind: .backgroundMusic)

  #expect(
    try TandemListeningModeProtocol.parameterRequest(sequence: 0, inquiry: feature.inquiry)
      .payload == Data([0xE6, 0x09])
  )
  // Background music on, large room.
  #expect(
    try TandemListeningModeProtocol.setRequest(
      sequence: 0, feature: feature, on: true, room: .large
    ).payload == Data([0xE8, 0x09, 0x00, 0x02])
  )
  // Standard (off) keeps the room byte the device echoes back.
  #expect(
    try TandemListeningModeProtocol.setRequest(
      sequence: 1, feature: feature, on: false, room: .middle
    ).payload == Data([0xE8, 0x09, 0x01, 0x01])
  )
}

@Test func cinemaRequestIsAPlainOnOffWithNoRoomByte() throws {
  let feature = TandemListeningFeature(function: 0xE5, inquiry: 0x04, kind: .cinema)
  #expect(
    try TandemListeningModeProtocol.setRequest(
      sequence: 0, feature: feature, on: true, room: .middle
    ).payload == Data([0xE8, 0x04, 0x00])
  )
  #expect(
    try TandemListeningModeProtocol.setRequest(
      sequence: 1, feature: feature, on: false, room: .middle
    ).payload == Data([0xE8, 0x04, 0x01])
  )
}

@Test func capturedParametersDecodeToTheRightState() throws {
  let bgm = TandemListeningFeature(function: 0xEB, inquiry: 0x09, kind: .backgroundMusic)
  // E7 09 00 01 = background music on, middle room.
  let bgmOn = try TandemListeningModeProtocol.parseParameterResponse(
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data([0xE7, 0x09, 0x00, 0x01])
    ),
    feature: bgm
  )
  #expect(bgmOn.isOn)
  #expect(bgmOn.room == .middle)

  // E7 09 01 01 = standard.
  let bgmStandard = try TandemListeningModeProtocol.parseParameterResponse(
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data([0xE7, 0x09, 0x01, 0x01])
    ),
    feature: bgm
  )
  #expect(!bgmStandard.isOn)

  let cinema = TandemListeningFeature(function: 0xE5, inquiry: 0x04, kind: .cinema)
  // E7 04 00 = cinema on.
  let cinemaOn = try TandemListeningModeProtocol.parseParameterResponse(
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data([0xE7, 0x04, 0x00])
    ),
    feature: cinema
  )
  #expect(cinemaOn.isOn)
  #expect(cinemaOn.room == nil)
}

@Test func resolvePicksTheActiveModeAndDisablesEqualiserWhenNotStandard() {
  let features = TandemListeningCatalog.features(forDeclared: [0xEB, 0xE5])

  let standard = TandemListeningReading.resolve(
    features: features,
    states: [
      0x09: .init(isOn: false, room: .large),
      0x04: .init(isOn: false, room: nil),
    ]
  )
  #expect(standard.selection == .standard)
  #expect(!standard.disablesEqualizer)
  // Standard still remembers the room to restore.
  #expect(standard.savedRoom == .large)

  let cinema = TandemListeningReading.resolve(
    features: features,
    states: [
      0x09: .init(isOn: false, room: .middle),
      0x04: .init(isOn: true, room: nil),
    ]
  )
  #expect(cinema.selection == .cinema)
  #expect(cinema.disablesEqualizer)

  let bgm = TandemListeningReading.resolve(
    features: features,
    states: [
      0x09: .init(isOn: true, room: .small),
      0x04: .init(isOn: false, room: nil),
    ]
  )
  #expect(bgm.selection == .backgroundMusic(.small))
  #expect(bgm.disablesEqualizer)
}
