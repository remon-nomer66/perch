import Foundation

/// 2ウェイのクロスオーバー。入力を低域と高域に分ける。
///
/// ローパスとハイパスの biquad を同じカットオフで持つ（2次バターワース）。低域を中央に
/// 固定し、高域だけを空間化する用途に使う。状態を持つのでブロックをまたいで使い続ける。
public struct Crossover: Sendable {
  private var lowpass: Biquad
  private var highpass: Biquad
  public let cutoff: Double

  public init(cutoff: Double, sampleRate: Double) {
    self.cutoff = cutoff
    lowpass = .lowpass(cutoff: cutoff, sampleRate: sampleRate)
    highpass = .highpass(cutoff: cutoff, sampleRate: sampleRate)
  }

  public mutating func split(_ input: [Float]) -> (low: [Float], high: [Float]) {
    (low: lowpass.process(input), high: highpass.process(input))
  }

  public mutating func reset() {
    lowpass.reset()
    highpass.reset()
  }
}
