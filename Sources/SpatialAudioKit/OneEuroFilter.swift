import Foundation

/// One Euro フィルタ（Casiez et al. 2012）。静止時はジッタを強く均し、速い動きには
/// カットオフを上げて追従する速度適応ローパス。
///
/// 時刻は呼び出し側が dt で渡す（実時計を読まない）ので、テストが決定的になる。
public struct OneEuroFilter: Sendable {
  private let minCutoff: Double
  private let beta: Double
  private let derivativeCutoff: Double
  private var lastValue: Double?
  /// 速度は生の入力同士の差から取る（原典実装の lastRawValue に相当）。濾過後の値から
  /// 取ると、入力が止まっても追い付くまで速度が残り、カットオフが不当に高止まりする。
  private var lastRaw: Double?
  private var lastDerivative = 0.0

  /// - Parameters:
  ///   - minCutoff: 静止時のカットオフ周波数(Hz)。小さいほど滑らか（遅れる）。
  ///   - beta: 速度への感度。大きいほど速い動きに食いつく。
  ///   - derivativeCutoff: 速度推定自体のローパス(Hz)。
  public init(minCutoff: Double = 1.0, beta: Double = 0.05, derivativeCutoff: Double = 1.0) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivativeCutoff = derivativeCutoff
  }

  public mutating func filter(_ value: Double, dt: Double) -> Double {
    guard dt > 0, let previous = lastValue, let previousRaw = lastRaw else {
      lastValue = value
      lastRaw = value
      return value
    }
    let rawDerivative = (value - previousRaw) / dt
    lastDerivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - lastDerivative)
    let cutoff = minCutoff + beta * abs(lastDerivative)
    let filtered = previous + Self.alpha(cutoff: cutoff, dt: dt) * (value - previous)
    lastValue = filtered
    lastRaw = value
    return filtered
  }

  static func alpha(cutoff: Double, dt: Double) -> Double {
    let tau = 1 / (2 * .pi * cutoff)
    return 1 / (1 + tau / dt)
  }
}

/// 回転版 One Euro。速度は角距離/秒で測り、補間は球面（slerp）で行う。
/// Euler 成分ごとに掛けると軸が結合したとき破綻するため、回転そのものを均す。
public struct RotationOneEuroFilter: Sendable {
  private let minCutoff: Double
  private let beta: Double
  private let derivativeCutoff: Double
  private var state: Rotation?
  private var lastRaw: Rotation?
  private var speed = 0.0

  public init(minCutoff: Double = 1.0, beta: Double = 0.3, derivativeCutoff: Double = 1.0) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivativeCutoff = derivativeCutoff
  }

  public mutating func filter(_ rotation: Rotation, dt: Double) -> Rotation {
    guard dt > 0, let current = state, let previousRaw = lastRaw else {
      state = rotation
      lastRaw = rotation
      return rotation
    }
    let rawSpeed = previousRaw.angle(to: rotation) / dt
    speed += OneEuroFilter.alpha(cutoff: derivativeCutoff, dt: dt) * (rawSpeed - speed)
    let cutoff = minCutoff + beta * speed
    let next = current.slerp(to: rotation, fraction: OneEuroFilter.alpha(cutoff: cutoff, dt: dt))
    state = next
    lastRaw = rotation
    return next
  }
}
