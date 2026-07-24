import Foundation

/// 2ウェイのクロスオーバー。入力を低域と高域に分ける。
///
/// **Linkwitz-Riley 2次**（Q=0.5 の LP/HP ＋ ハイパスの極性反転）。分けた帯域は最終的に
/// 耳で再合成されるので、和が平坦になる整列が要る。バターワース（Q=0.707）の LP+HP の
/// 同相和はカットオフで厳密にゼロ — 250Hz 付近（男声・ベース上部）がノッチ状に欠ける。
/// LR2 の LP−HP は全域で |H|=1 のオールパスになり、この欠けが消える。
/// 低域を中央に固定し、高域だけを空間化する用途に使う。状態を持つのでブロックをまたいで
/// 使い続ける。
public struct Crossover: Sendable {
  private var lowpass: Biquad
  private var highpass: Biquad
  public let cutoff: Double

  /// LR2 = 1次バターワース2段 ＝ 2次 Q=0.5。
  private static let linkwitzRileyQ = 0.5

  public init(cutoff: Double, sampleRate: Double) {
    self.cutoff = cutoff
    lowpass = .lowpass(cutoff: cutoff, sampleRate: sampleRate, q: Self.linkwitzRileyQ)
    highpass = .highpass(cutoff: cutoff, sampleRate: sampleRate, q: Self.linkwitzRileyQ)
  }

  public mutating func split(_ input: [Float]) -> (low: [Float], high: [Float]) {
    let low = lowpass.process(input)
    // 極性反転が LR2 の整列の要: LP+(−HP) の和がオールパス（平坦）になる。
    var high = highpass.process(input)
    for index in high.indices {
      high[index] = -high[index]
    }
    return (low: low, high: high)
  }

  public mutating func reset() {
    lowpass.reset()
    highpass.reset()
  }
}
