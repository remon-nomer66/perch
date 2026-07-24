import Foundation

/// フラックス列から適応しきい値で onset（拍の立ち上がり）を拾う。
///
/// フラックスの平均と分散を指数移動平均で追い、「平均×余裕 + 感度×標準偏差」を
/// 超えた瞬間を onset とする。音量や曲調の変化には自動で慣れる（librosa の
/// ピークピッキングのストリーミング版）。連打を防ぐ不応期と、無音の微小な揺れを
/// 拍にしない下限を持つ。
public struct OnsetPeakPicker: Sendable {
  private var mean = ExponentialAverage()
  private var meanSquare = ExponentialAverage()
  private var timeSinceOnset: Double

  private let timeConstant: Double
  private let sensitivity: Double
  private let refractory: Double
  private let minFlux: Double

  /// 一定のフラックスに慣れ切ったとき、しきい値が平均をわずかに上回るための余裕。
  private static let meanHeadroom = 1.2

  public init(
    timeConstant: Double = 1.5,
    sensitivity: Double = 1.5,
    refractory: Double = 0.12,
    minFlux: Double = 0.003
  ) {
    self.timeConstant = timeConstant
    self.sensitivity = sensitivity
    self.refractory = refractory
    self.minFlux = minFlux
    timeSinceOnset = refractory  // 最初の onset をすぐ拾えるように
  }

  /// 1ホップ分のフラックスを観測。onset なら強さ(0<s≤1)、無ければ 0 を返す。
  public mutating func observe(flux: Double, dt: Double) -> Double {
    let alpha = ExponentialAverage.alpha(dt: dt, timeConstant: timeConstant)
    mean.update(flux, alpha: alpha)
    meanSquare.update(flux * flux, alpha: alpha)
    timeSinceOnset += dt

    let variance = max(meanSquare.value - mean.value * mean.value, 0)
    let deviation = variance.squareRoot()
    let threshold = max(mean.value * Self.meanHeadroom + sensitivity * deviation, minFlux)
    guard timeSinceOnset >= refractory, flux >= threshold else { return 0 }

    timeSinceOnset = 0
    // しきい値ちょうどで 0.3、しきい値の2倍相当で 1.0 に飽和する連続な強さ。
    let excess = (flux - threshold) / max(sensitivity * deviation, threshold)
    return min(0.3 + 0.7 * excess, 1.0)
  }
}
