import Foundation
import Testing

@testable import SpatialAudioKit

@Test func zeroDegreesMeansNoMovement() {
  let wander = PositionWander(degrees: 0)
  let offset = wander.offset(source: 0, time: 12.3)
  #expect(offset.azimuth == 0)
  #expect(offset.elevation == 0)
}

@Test func theAzimuthStaysWithinTheAmplitude() {
  // 何秒経っても振れ幅を超えない（合成係数が 1 に正規化されている）。
  let degrees = 6.0
  let wander = PositionWander(degrees: degrees)
  let limit = degrees * .pi / 180 + 1e-9
  for step in 0..<2000 {
    let time = Double(step) * 0.05
    for source in 0..<3 {
      let offset = wander.offset(source: source, time: time)
      #expect(abs(offset.azimuth) <= limit)
      #expect(abs(offset.elevation) <= limit * 0.5 + 1e-9)
    }
  }
}

@Test func differentSourcesDoNotMoveInLockstep() {
  // 音源ごとに位相が違うので、同時刻でも位置がそろわない。
  let wander = PositionWander(degrees: 8)
  let a = wander.offset(source: 0, time: 3.0)
  let b = wander.offset(source: 1, time: 3.0)
  #expect(abs(a.azimuth - b.azimuth) > 1e-6)
}

@Test func theMovementIsContinuousBetweenNearbyTimes() {
  // 近い時刻では位置がほとんど変わらない（滑らか＝ビリビリしない）。
  let wander = PositionWander(degrees: 10)
  let now = wander.offset(source: 2, time: 5.0)
  let soon = wander.offset(source: 2, time: 5.01)
  #expect(abs(now.azimuth - soon.azimuth) < 0.01)
}

// MARK: - テンポ同期版

@Test func theTempoSyncedWanderRepeatsEvery32Beats() {
  // 主揺らぎ8拍（2小節）＋副揺らぎ32拍 → 32拍（8小節）でぴったり一周する。
  let wander = PositionWander(degrees: 8)
  let a = wander.offset(source: 0, beats: 3.2)
  let b = wander.offset(source: 0, beats: 3.2 + 32)
  #expect(abs(a.azimuth - b.azimuth) < 1e-9)
  #expect(abs(a.elevation - b.elevation) < 1e-9)
}

@Test func theTempoSyncedWanderMovesGently() {
  // ジッパーノイズ防止: 120BPM相当（1秒=2拍）でも角速度が緩やかであること。
  let wander = PositionWander(degrees: 6)
  var maxStep = 0.0
  var previous = wander.offset(source: 0, beats: 0).azimuth
  for step in 1..<2000 {
    let beats = Double(step) * 0.0214  // 10.7msブロック×120BPM
    let now = wander.offset(source: 0, beats: beats).azimuth
    maxStep = max(maxStep, abs(now - previous))
    previous = now
  }
  // 1ブロックの歩幅が約0.1°未満（旧・自由揺らぎの数倍以内）。
  #expect(maxStep < 0.1 * .pi / 180)
}

@Test func theTempoSyncedWanderStaysWithinTheAmplitude() {
  let degrees = 6.0
  let wander = PositionWander(degrees: degrees)
  let limit = degrees * .pi / 180 + 1e-9
  for step in 0..<2000 {
    let beats = Double(step) * 0.02
    for source in 0..<3 {
      let offset = wander.offset(source: source, beats: beats)
      #expect(abs(offset.azimuth) <= limit)
      #expect(abs(offset.elevation) <= limit * 0.5 + 1e-9)
    }
  }
}

@Test func tempoSyncedSourcesDoNotMoveInLockstep() {
  let wander = PositionWander(degrees: 8)
  let a = wander.offset(source: 0, beats: 5.0)
  let b = wander.offset(source: 1, beats: 5.0)
  #expect(abs(a.azimuth - b.azimuth) > 1e-6)
}

@Test func zeroDegreesMeansNoTempoSyncedMovementEither() {
  let wander = PositionWander(degrees: 0)
  let offset = wander.offset(source: 1, beats: 7.5)
  #expect(offset.azimuth == 0)
  #expect(offset.elevation == 0)
}
