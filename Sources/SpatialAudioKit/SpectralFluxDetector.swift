import Foundation

/// 音声ストリームからスペクトルフラックスで onset（拍の立ち上がり）を検出する。
///
/// フレーム（fftSize）を hopSize ずつ進めながら、対数圧縮した振幅スペクトルの
/// 半波整流差分（増えた分だけ）を OnsetPeakPicker の適応しきい値にかける。
/// 全帯域のスペクトル変化を見るので、キック頼みの低音エネルギー比より、
/// スネア・ボーカル等の立ち上がりも拾える。48kHz・既定値でホップは約10.7ms。
/// 内部状態を持つため、1インスタンスは単一スレッドから使うこと。
public final class SpectralFluxDetector {
  private let analyzer: SpectrumAnalyzer
  private let fftSize: Int
  private let hopSize: Int
  private let hopDuration: Double
  private let compression: Float
  private var picker: OnsetPeakPicker
  private var tempo = TempoEstimator()
  private var pending: [Float] = []
  private var previousSpectrum: [Float]

  /// フラックス包絡の自己相関によるテンポ推定。周期性が確認できないときは nil。
  public var estimatedBPM: Double? { tempo.bpm }

  /// fftSize は 64 以上の 2 の冪、hopSize は 1〜fftSize。満たさなければ作れない。
  public init?(
    sampleRate: Double,
    fftSize: Int = 1024,
    hopSize: Int = 512,
    compression: Float = 100,
    picker: OnsetPeakPicker = OnsetPeakPicker()
  ) {
    guard sampleRate > 0, hopSize > 0, hopSize <= fftSize,
      let analyzer = SpectrumAnalyzer(size: fftSize)
    else { return nil }
    self.analyzer = analyzer
    self.fftSize = fftSize
    self.hopSize = hopSize
    hopDuration = Double(hopSize) / sampleRate
    self.compression = compression
    self.picker = picker
    previousSpectrum = [Float](repeating: 0, count: analyzer.binCount)
    pending.reserveCapacity(fftSize * 2)
  }

  /// モノラルのサンプル列を観測。このブロック中の最強 onset の強さ(0<s≤1)か 0 を返す。
  public func observe(mono samples: [Float]) -> Double {
    pending.append(contentsOf: samples)
    var strongest = 0.0
    while pending.count >= fftSize {
      let frame = Array(pending[0..<fftSize])
      pending.removeFirst(hopSize)
      let spectrum = SpectralFlux.logCompressed(analyzer.magnitudes(frame), gamma: compression)
      let flux = SpectralFlux.flux(previous: previousSpectrum, current: spectrum)
      previousSpectrum = spectrum
      tempo.observe(flux: flux, dt: hopDuration)
      let strength = picker.observe(flux: flux, dt: hopDuration)
      if strength > strongest { strongest = strength }
    }
    return strongest
  }

  /// ステレオを (L+R)/2 でモノ化して観測する。
  public func observe(left: [Float], right: [Float]) -> Double {
    let count = min(left.count, right.count)
    guard count > 0 else { return 0 }
    var mono = [Float](repeating: 0, count: count)
    for index in 0..<count {
      mono[index] = (left[index] + right[index]) * 0.5
    }
    return observe(mono: mono)
  }
}
