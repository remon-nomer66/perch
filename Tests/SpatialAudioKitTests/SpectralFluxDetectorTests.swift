import Foundation
import Testing

@testable import SpatialAudioKit

private let sampleRate = 48_000.0

/// クリックトラックを作る: 低レベルの持続音の上に、鋭い立ち上がりのバーストを置く。
/// クリック時刻（秒）を指定。背景は 220Hz、クリックは 2kHz の 30ms バースト。
private func clickTrack(
  duration: Double,
  clickTimes: [Double],
  clickAmplitude: Float,
  backgroundAmplitude: Float
) -> [Float] {
  let frameCount = Int(duration * sampleRate)
  var samples = ToneGenerator.sine(
    frequency: 220, sampleRate: sampleRate, frameCount: frameCount,
    amplitude: Double(backgroundAmplitude))
  let clickLength = Int(0.03 * sampleRate)
  for time in clickTimes {
    let start = Int(time * sampleRate)
    for offset in 0..<clickLength where start + offset < frameCount {
      let phase = 2.0 * Double.pi * 2_000 * Double(offset) / sampleRate
      samples[start + offset] += clickAmplitude * Float(sin(phase))
    }
  }
  return samples
}

/// 512サンプルずつ（実機のコールバック相当で）流し、onset の検出時刻を集める。
private func detectOnsets(_ samples: [Float], detector: SpectralFluxDetector) -> [Double] {
  var times: [Double] = []
  var position = 0
  while position < samples.count {
    let end = min(position + 512, samples.count)
    let chunk = Array(samples[position..<end])
    if detector.observe(mono: chunk) > 0 {
      times.append(Double(end) / sampleRate)
    }
    position = end
  }
  return times
}

@Test func everyClickIsDetectedCloseToItsTime() {
  let detector = SpectralFluxDetector(sampleRate: sampleRate)
  #expect(detector != nil)
  let clicks = [0.35, 0.85, 1.35, 1.85]
  let samples = clickTrack(
    duration: 2.2, clickTimes: clicks, clickAmplitude: 0.8, backgroundAmplitude: 0.05)
  let onsets = detectOnsets(samples, detector: detector!)

  // 各クリックの直後（窓1枚+チャンク遅れの範囲）に onset があること。
  for click in clicks {
    let matched = onsets.contains { $0 >= click && $0 <= click + 0.06 }
    #expect(matched, "クリック \(click)s が検出されていない: \(onsets)")
  }
  // 静かな区間での誤検出がないこと（曲頭の立ち上がりだけは許す）。
  let spurious = onsets.filter { time in
    time > 0.1 && !clicks.contains { time >= $0 && time <= $0 + 0.06 }
  }
  #expect(spurious.isEmpty, "誤検出: \(spurious)")
}

@Test func aSteadyToneProducesNoOnsetsAfterItsStart() {
  let detector = SpectralFluxDetector(sampleRate: sampleRate)!
  let samples = ToneGenerator.sine(
    frequency: 440, sampleRate: sampleRate, frameCount: Int(1.5 * sampleRate), amplitude: 0.5)
  let onsets = detectOnsets(samples, detector: detector)
  // 出だしの1発だけは音の開始として正しい。それ以降は出ない。
  #expect(onsets.filter { $0 > 0.1 }.isEmpty)
}

@Test func silenceProducesNoOnsets() {
  let detector = SpectralFluxDetector(sampleRate: sampleRate)!
  let samples = [Float](repeating: 0, count: Int(1.0 * sampleRate))
  #expect(detectOnsets(samples, detector: detector).isEmpty)
}

@Test func quietClicksAreStillDetected() {
  // 対数圧縮の狙い: 小音量でもクリックの立ち上がりを拾えること。
  let detector = SpectralFluxDetector(sampleRate: sampleRate)!
  let clicks = [0.4, 0.9, 1.4]
  let samples = clickTrack(
    duration: 1.8, clickTimes: clicks, clickAmplitude: 0.1, backgroundAmplitude: 0.01)
  let onsets = detectOnsets(samples, detector: detector)
  let matchedCount = clicks.filter { click in
    onsets.contains { $0 >= click && $0 <= click + 0.06 }
  }.count
  #expect(matchedCount >= 2, "小音量クリックの検出が少なすぎる: \(onsets)")
}

@Test func stereoObservationMatchesItsMonoMix() {
  let clicks = [0.4, 0.9]
  let samples = clickTrack(
    duration: 1.3, clickTimes: clicks, clickAmplitude: 0.8, backgroundAmplitude: 0.05)

  let monoDetector = SpectralFluxDetector(sampleRate: sampleRate)!
  let monoOnsets = detectOnsets(samples, detector: monoDetector)

  // 同一のL/Rを与えたステレオ観測は、モノ観測と同じ結果になる。
  let stereoDetector = SpectralFluxDetector(sampleRate: sampleRate)!
  var stereoOnsets: [Double] = []
  var position = 0
  while position < samples.count {
    let end = min(position + 512, samples.count)
    let chunk = Array(samples[position..<end])
    if stereoDetector.observe(left: chunk, right: chunk) > 0 {
      stereoOnsets.append(Double(end) / sampleRate)
    }
    position = end
  }
  #expect(stereoOnsets == monoOnsets)
}

@Test func anInvalidConfigurationFailsToInitialise() {
  #expect(SpectralFluxDetector(sampleRate: sampleRate, fftSize: 1000) == nil)
  #expect(SpectralFluxDetector(sampleRate: sampleRate, fftSize: 1024, hopSize: 0) == nil)
  #expect(SpectralFluxDetector(sampleRate: sampleRate, fftSize: 512, hopSize: 1024) == nil)
  #expect(SpectralFluxDetector(sampleRate: 0) == nil)
}
