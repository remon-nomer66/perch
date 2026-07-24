import Foundation

/// 較正時からの相対距離（比率）の推定。
///
/// 絶対距離は使わない: macOS では焦点距離が取れず（`videoFieldOfView` は unavailable）、
/// 個人の瞳孔間距離の仮定も大きな誤差源になる。較正時のピクセル瞳孔間距離 `referenceIPD`
/// を基準に `referenceIPD / 今のIPD` を返せば、焦点距離も個人差も分子分母で相殺される。
///
/// - 横を向くと瞳の間隔は投影で縮み「遠ざかった」ように見えるため、|yaw| がゲートを
///   超えている間は更新しない（最後の値を保つ）。
/// - 単発の外れ値（誤検出・瞬き）は棄却し、同水準が2回続いたときだけ本物の移動と認める。
/// - 瞳が取れない遠距離は、瞳が取れていた間に学習した 顔枠幅×比率 の積（距離に依らず
///   ほぼ一定）で顔枠幅から代算する。
public struct RelativeDistanceEstimator: Sendable {
  private let referenceIPD: Double
  private let yawGate: Double
  private let smoothing: Double
  private let maxStep: Double
  private let range: ClosedRange<Double>

  private var lastAccepted = 1.0
  private var pending: Double?
  private var widthScale: Double?

  /// 現在の推定比率。1.0 が較正時の距離、2.0 は倍の距離。
  public private(set) var ratio = 1.0

  /// - Parameters:
  ///   - referenceIPD: 較正時のピクセル瞳孔間距離。
  ///   - yawGate: これを超える |yaw|（ラジアン）では距離を更新しない。
  ///   - smoothing: 受理した値へ寄せる割合（0…1）。
  ///   - maxStep: 1更新で許す倍率。超えたら外れ値として保留する。
  ///   - range: 比率として意味を認める範囲。外はクランプ。
  public init(
    referenceIPD: Double,
    yawGate: Double = .pi / 9,
    smoothing: Double = 0.25,
    maxStep: Double = 1.3,
    range: ClosedRange<Double> = 0.4...5.0
  ) {
    self.referenceIPD = max(referenceIPD, .ulpOfOne)
    self.yawGate = yawGate
    self.smoothing = smoothing
    self.maxStep = maxStep
    self.range = range
  }

  @discardableResult
  public mutating func update(pixelIPD: Double?, faceWidth: Double?, yaw: Double) -> Double {
    guard abs(yaw) <= yawGate else { return ratio }

    let candidate: Double?
    if let pixelIPD, pixelIPD > 0 {
      candidate = referenceIPD / pixelIPD
    } else if let faceWidth, faceWidth > 0, let widthScale {
      candidate = widthScale / faceWidth
    } else {
      candidate = nil
    }
    guard let raw = candidate else { return ratio }
    let clamped = min(max(raw, range.lowerBound), range.upperBound)

    let step = clamped / lastAccepted
    if step > maxStep || step < 1 / maxStep {
      // 突然の大ジャンプ。前回も同水準へ跳んでいた（2連続）なら本物の移動と認める。
      if let pending, max(pending, clamped) / min(pending, clamped) <= maxStep {
        self.pending = nil
      } else {
        pending = clamped
        return ratio
      }
    } else {
      pending = nil
    }

    lastAccepted = clamped
    ratio += smoothing * (clamped - ratio)

    // 瞳が実測できている間だけ、顔枠幅のフォールバック係数を学習する。
    if pixelIPD != nil, let faceWidth, faceWidth > 0 {
      let product = faceWidth * clamped
      widthScale = widthScale.map { $0 + 0.1 * (product - $0) } ?? product
    }
    return ratio
  }
}
