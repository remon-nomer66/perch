import Foundation
import Testing

@testable import SpatialAudioKit

@available(macOS 14.4, *)
@Test func lowContentGoesToBothEarsNotTheSpatialSources() {
  // 低域は両耳の直通路（bassLeft/bassRight）へ。空間化する中央・左右には出さない。
  let low: [Float] = [0.8, -0.4]
  let silent: [Float] = [0, 0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: low, lowRight: low, highLeft: silent, highRight: silent,
    lowGain: 1, midGain: 1, width: 1.1
  )
  #expect(mixed.bassLeft == low)
  #expect(mixed.bassRight == low)
  #expect(mixed.center.allSatisfy { $0 == 0 })
  #expect(mixed.sideLeft.allSatisfy { $0 == 0 })
  #expect(mixed.sideRight.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func lowGainBoostsTheBassInBothEars() {
  // 低域ゲインは両耳のベースを持ち上げる（力強さの調整）。
  let low: [Float] = [0.5]
  let silent: [Float] = [0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: low, lowRight: low, highLeft: silent, highRight: silent,
    lowGain: 2, midGain: 1, width: 1
  )
  #expect(abs(mixed.bassLeft[0] - 1.0) < 1e-6)
  #expect(abs(mixed.bassRight[0] - 1.0) < 1e-6)
}

@available(macOS 14.4, *)
@Test func centredHighContentGoesToTheCentreScaledByMidGain() {
  // 中央成分（L==R の中高域）は中央へ。midGain で歌詞を前に出せる。
  let silent: [Float] = [0, 0]
  let high: [Float] = [0.4, 0.4]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: high, highRight: high,
    lowGain: 1, midGain: 1.5, width: 1
  )
  #expect(abs(mixed.center[0] - 0.6) < 1e-6)  // 0.4 * 1.5
  #expect(mixed.sideLeft.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func pannedHighContentIsWidenedIntoTheSides() {
  // 片chの中高域はサイドへ。width で強調、左右は反転。
  let silent: [Float] = [0]
  let highLeft: [Float] = [1.0]
  let highRight: [Float] = [0.0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: highLeft, highRight: highRight,
    lowGain: 1, midGain: 1, width: 2.0
  )
  #expect(abs(mixed.sideLeft[0] - 1.0) < 1e-6)   // (1-0)/2 * 2
  #expect(abs(mixed.sideRight[0] - (-1.0)) < 1e-6)
  #expect(abs(mixed.center[0] - 0.5) < 1e-6)     // mid = (1+0)/2
}

@available(macOS 14.4, *)
@Test func mismatchedBandLengthsUseTheShortest() {
  let mixed = MultibandSpatializer.mix(
    lowLeft: [1, 2, 3], lowRight: [1, 2], highLeft: [0], highRight: [0],
    lowGain: 1, midGain: 1, width: 1
  )
  #expect(mixed.center.count == 1)
}

// MARK: - サンプルレート照合

@available(macOS 14.4, *)
@Test func theTapsReportedRateMustMatchTheGraphsRate() {
  // 一致（微小な浮動小数差込み）は通す。実レートが違えば弾く — 48kHz 決め打ちのまま
  // 44.1kHz の機器で動かすと全システム音の速度とピッチが狂うため。
  #expect(MultibandSpatializer.sampleRateMatches(expected: 48_000, reported: 48_000))
  #expect(MultibandSpatializer.sampleRateMatches(expected: 44_100, reported: 44_100.0001))
  #expect(!MultibandSpatializer.sampleRateMatches(expected: 48_000, reported: 44_100))
  #expect(!MultibandSpatializer.sampleRateMatches(expected: 48_000, reported: 96_000))
}

@available(macOS 14.4, *)
@Test func anUnreadableTapRateDoesNotBlockStarting() {
  // 0 は「フォーマットを読めていない」— 照合できない以上、開始は妨げない。
  #expect(MultibandSpatializer.sampleRateMatches(expected: 48_000, reported: 0))
  #expect(MultibandSpatializer.sampleRateMatches(expected: 48_000, reported: -1))
}

// MARK: - 取得確認の無音判定

@available(macOS 14.4, *)
@Test func signalInOnlyTheRightChannelStillProvesCapture() throws {
  // ハードパンされた素材は片チャンネルにしか信号を持たない。左だけを見ていると
  // 「音声が検出できない」と誤判定して 12 秒後にオフへ戻してしまう。
  let spatializer = try MultibandSpatializer(muteOriginal: false)
  let silent = [Float](repeating: 0, count: 256)
  var rightOnly = [Float](repeating: 0, count: 256)
  rightOnly[10] = 0.5
  #expect(!spatializer.hasAudioSignal)
  spatializer.feed(left: silent, right: rightOnly)
  #expect(spatializer.hasAudioSignal)
}

@available(macOS 14.4, *)
@Test func silenceInBothChannelsDoesNotProveCapture() throws {
  let spatializer = try MultibandSpatializer(muteOriginal: false)
  let silent = [Float](repeating: 0, count: 256)
  spatializer.feed(left: silent, right: silent)
  #expect(!spatializer.hasAudioSignal)
  #expect(spatializer.hasReceivedAudio)
}

// MARK: - 出力構成の変更通知

@available(macOS 14.4, *)
@Test func anEngineConfigurationChangeReachesTheOwner() throws {
  // エンジンは構成変更で黙って止まる。所有者が作り直せるよう、通知が転送されること。
  let spatializer = try MultibandSpatializer(muteOriginal: false)
  let hit = OSAllocatedUnfairLockedBox(false)
  spatializer.onConfigurationChange = { hit.set(true) }
  NotificationCenter.default.post(
    name: .AVAudioEngineConfigurationChange,
    object: spatializer.graphEngineForNotifications
  )
  #expect(hit.get())
}

/// 通知クロージャ（@Sendable）から書ける最小の箱。
private final class OSAllocatedUnfairLockedBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool
  init(_ value: Bool) { self.value = value }
  func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
  func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
