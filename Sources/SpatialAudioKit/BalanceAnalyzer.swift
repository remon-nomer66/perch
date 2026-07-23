import Foundation

/// 直近の音のバランスを常時測り、空間化パラメータをゆっくり自動調整する。
///
/// 低/中/サイドの各エネルギーをローリング窓（EMA）で測り、そこから低音ゲインと
/// 広がりの「目標値」を算出、実際の適用値はスルー（別のEMA）で滑らかに寄せる。
/// これで「急変させない」「曲が変わったら数秒で追従」を両立する。基準は今の良い
/// 既定値（baseline）で、そこから content に応じて外れすぎない範囲で動かす。
public struct BalanceAnalyzer: Sendable {
  // クランプと目標比（経験則。実機で詰める）。
  static let lowGainRange: ClosedRange<Float> = 1.0...2.2
  static let widthRange: ClosedRange<Float> = 0.8...1.8
  static let desiredLowRatio = 1.0  // 低音レベル ≒ 中央レベル を狙う
  static let desiredSideRatio = 0.5  // ほどほどの広がりを狙う

  private var lowEnergy = ExponentialAverage()
  private var midEnergy = ExponentialAverage()
  private var sideEnergy = ExponentialAverage()
  private var lowGainSlew: ExponentialAverage
  private var widthSlew: ExponentialAverage

  private let baselineLowGain: Float
  private let baselineWidth: Float
  private let windowSeconds: Double
  private let slewSeconds: Double

  public init(
    baselineLowGain: Float,
    baselineWidth: Float,
    windowSeconds: Double = 3,
    slewSeconds: Double = 5
  ) {
    self.baselineLowGain = baselineLowGain
    self.baselineWidth = baselineWidth
    self.windowSeconds = windowSeconds
    self.slewSeconds = slewSeconds
    lowGainSlew = ExponentialAverage(initial: Double(baselineLowGain))
    widthSlew = ExponentialAverage(initial: Double(baselineWidth))
  }

  /// 1ブロックぶんの各帯域 RMS を観測し、目標へ向けてゆっくり更新する。
  public mutating func observe(lowRMS: Double, midRMS: Double, sideRMS: Double, dt: Double) {
    let windowAlpha = ExponentialAverage.alpha(dt: dt, timeConstant: windowSeconds)
    lowEnergy.update(lowRMS * lowRMS, alpha: windowAlpha)
    midEnergy.update(midRMS * midRMS, alpha: windowAlpha)
    sideEnergy.update(sideRMS * sideRMS, alpha: windowAlpha)

    let target = Self.targets(
      lowEnergy: lowEnergy.value, midEnergy: midEnergy.value, sideEnergy: sideEnergy.value,
      baselineLowGain: baselineLowGain, baselineWidth: baselineWidth
    )
    let slewAlpha = ExponentialAverage.alpha(dt: dt, timeConstant: slewSeconds)
    lowGainSlew.update(Double(target.lowGain), alpha: slewAlpha)
    widthSlew.update(Double(target.width), alpha: slewAlpha)
  }

  /// 現在の（滑らかに追従した）適用値。
  public var lowGain: Float { Float(lowGainSlew.value) }
  public var sideWidth: Float { Float(widthSlew.value) }

  /// 帯域エネルギー（平均二乗）から目標パラメータを算出する純関数。
  /// 中央（mid）を基準に、低音が少なければ持ち上げ、既に広ければ幅を抑える。
  static func targets(
    lowEnergy: Double, midEnergy: Double, sideEnergy: Double,
    baselineLowGain: Float, baselineWidth: Float
  ) -> (lowGain: Float, width: Float) {
    let epsilon = 1e-9
    let lowLevel = lowEnergy.squareRoot()
    let midLevel = midEnergy.squareRoot()
    let sideLevel = sideEnergy.squareRoot()

    let lowRatio = lowLevel / (midLevel + epsilon)
    let lowGain = Double(baselineLowGain) * (desiredLowRatio / (lowRatio + epsilon))

    let sideRatio = sideLevel / (midLevel + epsilon)
    let width = Double(baselineWidth) * (desiredSideRatio / (sideRatio + epsilon))

    return (
      clamp(Float(lowGain), lowGainRange),
      clamp(Float(width), widthRange)
    )
  }

  private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
    min(max(value, range.lowerBound), range.upperBound)
  }
}
