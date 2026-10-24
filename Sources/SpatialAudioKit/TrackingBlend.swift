import Foundation

/// 顔ロスト・後ろ向きの受け皿。追跡が切れたら音場をゆっくり正面（中立）へ戻し、
/// 復帰したらゆっくり追従へ戻す。土台の出力は常に 中立…追跡値 の間のクロスフェード。
///
/// 距離も同じ重みで中立(1.0)へ寄せる: 暗所・横向きの検出失敗を「離席」と誤解して
/// 音量を下げないため、ロストは常に「効果を抜く」側に倒す。
///
/// 後ろ向きのときは、この土台の上に `FacingAwayTurn` を重ねて真後ろへ回す。土台は
/// ロストと同じく中立へ向かうので、距離比も中立へ戻る — 背を向けると瞳の間隔は測れず、
/// 振り向いたついでに立ち上がって動くことも多いので、最後に測った距離を保つ根拠が無い。
/// 誤って後ろ向きと判定したときにも音量を下げない側に倒れる。
public struct TrackingBlend: Sendable {
  /// 1フレームの行き先。
  public enum Target: Sendable, Equatable {
    /// 顔を追っている。距離比が測れなかったフレームは nil（最後の値を保つ）。
    case tracked(Rotation, distanceRatio: Double?)
    /// 顔を見失った（誰もいない・判定できない）。正面へ戻す。
    case lost
    /// 後ろを向いている。真後ろへ回す。
    case facingAway
  }

  private let fadeIn: Double
  private let fadeOut: Double
  private var weight = 0.0
  private var held = Rotation.identity
  private var heldRatio = 1.0
  private var turn: FacingAwayTurn

  /// - Parameters:
  ///   - fadeIn: 追跡復帰時に効果へ戻るまでの秒数。
  ///   - fadeOut: ロスト時に正面へ戻るまでの秒数。
  ///   - turn: 後ろ向きのときに真後ろへ回す層。
  public init(fadeIn: Double = 0.4, fadeOut: Double = 2.0, turn: FacingAwayTurn = FacingAwayTurn()) {
    self.fadeIn = max(0.001, fadeIn)
    self.fadeOut = max(0.001, fadeOut)
    self.turn = turn
  }

  /// 1フレームぶん進める。`tracked` が nil のフレームはロスト（後ろ向きは区別しない）。
  public mutating func advance(
    tracked: Rotation?,
    distanceRatio: Double?,
    dt: Double
  ) -> (rotation: Rotation, distanceRatio: Double) {
    advance(tracked.map { .tracked($0, distanceRatio: distanceRatio) } ?? .lost, dt: dt)
  }

  /// 1フレームぶん進める。
  public mutating func advance(
    _ target: Target, dt: Double
  ) -> (rotation: Rotation, distanceRatio: Double) {
    switch target {
    case .tracked(let rotation, let distanceRatio):
      held = rotation
      if let distanceRatio {
        heldRatio = distanceRatio
      }
      weight = min(1, weight + dt / fadeIn)
    case .lost, .facingAway:
      weight = max(0, weight - dt / fadeOut)
    }
    let base = Rotation.identity.slerp(to: held, fraction: weight)
    let rotation = turn.advance(
      base: base, lastTracked: held, isFacingAway: target == .facingAway, dt: dt
    )
    let ratio = 1 + (heldRatio - 1) * weight
    return (rotation, ratio)
  }

  /// 完全に中立へ戻りきったか（ロストが続いて効果が抜け、真後ろへも回っていない状態）。
  public var isNeutral: Bool { weight <= 0 && turn.isAtRest }
}
