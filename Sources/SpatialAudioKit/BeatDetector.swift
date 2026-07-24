import Foundation

/// エネルギーの立ち上がり（オンセット）から拍を検出する。
///
/// 速い包絡（fast）と遅い平均（slow）を比べ、fast が slow を閾値倍以上に急上昇した
/// 瞬間を拍とみなす。低音（キック）のレベルを入れると拍の指標として強い。正確な BPM は
/// 求めない（リアルタイムでは脆いため）。連打を防ぐ不応期と、無音での誤検出を防ぐ下限を持つ。
public struct BeatDetector: Sendable {
  private var fast = ExponentialAverage()
  private var slow = ExponentialAverage()
  private var timeSinceBeat: Double

  private let fastTimeConstant: Double
  private let slowTimeConstant: Double
  private let threshold: Double
  private let refractory: Double
  private let minLevel: Double

  public init(
    fastTimeConstant: Double = 0.03,
    slowTimeConstant: Double = 0.4,
    threshold: Double = 1.4,
    refractory: Double = 0.15,
    minLevel: Double = 0.004
  ) {
    self.fastTimeConstant = fastTimeConstant
    self.slowTimeConstant = slowTimeConstant
    self.threshold = threshold
    self.refractory = refractory
    self.minLevel = minLevel
    timeSinceBeat = refractory  // 最初の拍をすぐ拾えるように
  }

  /// 1ブロックのレベル（低音 RMS 等）を観測。拍なら強さ(0<s≤1)、無ければ 0 を返す。
  public mutating func observe(level: Double, dt: Double) -> Double {
    fast.update(level, alpha: ExponentialAverage.alpha(dt: dt, timeConstant: fastTimeConstant))
    slow.update(level, alpha: ExponentialAverage.alpha(dt: dt, timeConstant: slowTimeConstant))
    timeSinceBeat += dt

    guard timeSinceBeat >= refractory, fast.value >= minLevel, slow.value > 1e-9 else {
      return 0
    }
    let ratio = fast.value / slow.value
    guard ratio >= threshold else { return 0 }

    timeSinceBeat = 0
    // 弱い拍でも見える動きになるよう 0.3 を下駄にし、強い立ち上がりで 1 まで。
    return min((ratio - threshold) / threshold + 0.3, 1.0)
  }
}
