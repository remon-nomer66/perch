import Foundation

/// 指数移動平均。生の音を大量に貯めずに「直近◯秒の窓」を効率的に近似する。
///
/// 時定数（timeConstant 秒）ぶん過去の寄与が 1/e に減衰する。ブロック長が変動しても
/// 時間的に正しく重み付けできるよう、更新ごとに経過時間 `dt` から係数を作る。
/// バランス測定の窓にも、パラメータをゆっくり動かすスルーにも使う。
public struct ExponentialAverage: Sendable {
  public private(set) var value: Double

  public init(initial: Double = 0) {
    value = initial
  }

  public mutating func update(_ input: Double, alpha: Double) {
    let a = min(max(alpha, 0), 1)
    value += a * (input - value)
  }

  /// 経過時間 `dt` と時定数から更新係数を作る。dt≪timeConstant で小さく（ゆっくり）、
  /// dt≫timeConstant で 1 に近づく（即追従）。
  public static func alpha(dt: Double, timeConstant: Double) -> Double {
    guard timeConstant > 0 else { return 1 }
    guard dt > 0 else { return 0 }
    return 1 - exp(-dt / timeConstant)
  }
}
