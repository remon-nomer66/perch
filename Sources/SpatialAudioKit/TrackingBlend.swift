import Foundation

/// 顔ロスト時の受け皿。追跡が切れたら音場をゆっくり正面（中立）へ戻し、
/// 復帰したらゆっくり追従へ戻す。出力は常に 中立…追跡値 の間のクロスフェード。
///
/// 距離も同じ重みで中立(1.0)へ寄せる: 暗所・横向きの検出失敗を「離席」と誤解して
/// 音量を下げないため、ロストは常に「効果を抜く」側に倒す。
public struct TrackingBlend: Sendable {
  private let fadeIn: Double
  private let fadeOut: Double
  private var weight = 0.0
  private var held = Rotation.identity
  private var heldRatio = 1.0

  /// - Parameters:
  ///   - fadeIn: 追跡復帰時に効果へ戻るまでの秒数。
  ///   - fadeOut: ロスト時に正面へ戻るまでの秒数。
  public init(fadeIn: Double = 0.4, fadeOut: Double = 2.0) {
    self.fadeIn = max(0.001, fadeIn)
    self.fadeOut = max(0.001, fadeOut)
  }

  /// 1フレームぶん進める。`tracked` が nil のフレームはロスト。
  public mutating func advance(
    tracked: Rotation?,
    distanceRatio: Double?,
    dt: Double
  ) -> (rotation: Rotation, distanceRatio: Double) {
    if let tracked {
      held = tracked
      if let distanceRatio {
        heldRatio = distanceRatio
      }
      weight = min(1, weight + dt / fadeIn)
    } else {
      weight = max(0, weight - dt / fadeOut)
    }
    let rotation = Rotation.identity.slerp(to: held, fraction: weight)
    let ratio = 1 + (heldRatio - 1) * weight
    return (rotation, ratio)
  }

  /// 完全に中立へ戻りきったか（ロストが続いて効果が抜けた状態）。
  public var isNeutral: Bool { weight <= 0 }
}
