import Foundation
import Testing

@testable import SpatialAudioKit

private let sampleRate = 48_000.0

@Test func theRequestedLengthIsRenderedWithinRange() {
  var generator = BGMGenerator(bpm: 120, sampleRate: sampleRate)
  let (left, right) = generator.render(frameCount: 9_600)
  #expect(left.count == 9_600)
  #expect(right.count == 9_600)
  // クリップしない範囲で、無音でもないこと。
  #expect(left.allSatisfy { abs($0) <= 1 })
  #expect(right.allSatisfy { abs($0) <= 1 })
  #expect(left.contains { abs($0) > 0.05 })
}

@Test func theSameConfigurationRendersIdenticalAudio() {
  // 乱数もサンプル位置から決まる決定的な合成。答え合わせに使えるように再現可能。
  var first = BGMGenerator(bpm: 120, sampleRate: sampleRate)
  var second = BGMGenerator(bpm: 120, sampleRate: sampleRate)
  let a = first.render(frameCount: 4_800)
  let b = second.render(frameCount: 4_800)
  #expect(a.left == b.left)
  #expect(a.right == b.right)
  // 続きのブロックも一致する（内部位置が正しく進む）。
  #expect(first.render(frameCount: 4_800).left == second.render(frameCount: 4_800).left)
}

@Test func beatsCarryMoreLowEnergyThanOffbeats() {
  // 4つ打ちキックの分だけ、拍頭の低域は拍の裏より強い。
  var generator = BGMGenerator(bpm: 120, sampleRate: sampleRate)
  let (left, right) = generator.render(frameCount: Int(4.0 * sampleRate))
  var mono = [Float](repeating: 0, count: left.count)
  for index in 0..<left.count { mono[index] = (left[index] + right[index]) * 0.5 }
  var crossover = Crossover(cutoff: 150, sampleRate: sampleRate)
  let (low, _) = crossover.split(mono)

  func energy(from start: Double, duration: Double) -> Double {
    let begin = Int(start * sampleRate)
    let end = min(Int((start + duration) * sampleRate), low.count)
    guard begin < end else { return 0 }
    var sum = 0.0
    for index in begin..<end { sum += Double(low[index]) * Double(low[index]) }
    return sum / Double(end - begin)
  }

  // 120BPM → 拍は0.5秒ごと。最初の拍はフィルタの立ち上がりを避けて2拍目以降で測る。
  var onBeat = 0.0
  var offBeat = 0.0
  for beat in 2..<8 {
    let start = Double(beat) * 0.5
    onBeat += energy(from: start, duration: 0.1)
    offBeat += energy(from: start + 0.35, duration: 0.1)
  }
  #expect(onBeat > offBeat * 1.2)
}

@Test func theOnsetDetectorLocksToTheEighthNoteGrid() {
  // テンポ既知のBGMで答え合わせ: 検出された onset はすべて8分グリッドの直後に載る。
  var generator = BGMGenerator(bpm: 120, sampleRate: sampleRate)
  let (left, right) = generator.render(frameCount: Int(4.0 * sampleRate))
  var mono = [Float](repeating: 0, count: left.count)
  for index in 0..<left.count { mono[index] = (left[index] + right[index]) * 0.5 }

  let detector = SpectralFluxDetector(sampleRate: sampleRate)!
  var onsets: [Double] = []
  var position = 0
  while position < mono.count {
    let end = min(position + 512, mono.count)
    if detector.observe(mono: Array(mono[position..<end])) > 0 {
      onsets.append(Double(end) / sampleRate)
    }
    position = end
  }

  // 音楽的に十分な数の拍を拾うこと（4秒 = 8拍 + 裏拍）。
  #expect(onsets.count >= 8, "検出が少なすぎる: \(onsets)")
  // すべての onset が8分グリッド（0.25秒刻み）の直後60ms以内にあること。
  let eighth = 0.25
  for onset in onsets {
    let sinceGrid = onset.truncatingRemainder(dividingBy: eighth)
    #expect(sinceGrid <= 0.06, "グリッド外の誤検出: \(onset)s (+\(sinceGrid)s)")
  }
}
