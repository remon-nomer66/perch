import Foundation
import simd

/// 後ろ向きの間、音場を真後ろへ回す層。追跡・ロストの受け皿（`TrackingBlend`）の出力を
/// 土台に、そこから真後ろ — 較正した正面に対して yaw 180°、pitch・roll 0 — への
/// 補間を重ねる。音源（Mac）が聴き手の背後に来る向きで、背後の聞こえ方は空間ミキサーの
/// HRTF に任せる（こもり等の DSP は足さない）。
///
/// **回る側**: 真後ろは yaw +180° と -180° のどちらから回っても同じ向きなので、どちら側を
/// 通るかは決めないと定まらない。
/// - 回り始めは、最後に追跡していた yaw の側を通す（右へ振り向いていったなら右回り）。
///   クォータニオンの最短経路の slerp でもたいていはそうなるが、yaw ≈ 0 では経路が
///   残差の符号で決まってしまう。そこで |yaw| が `ambiguousYaw` 未満なら、手掛かりが
///   無いものとして正の yaw 側に決め打つ。
/// - 戻り始めは、戻ってきた顔の yaw の側を通す（出ていった側とは限らない）。曖昧なら
///   来た道を引き返す。
/// - 側を決め直すのは、層が端（回っていない／回りきった）にいるときだけ。そこではどちらの
///   側でも出力が同じなので、決め直しで音場が跳ばない。動いている途中は側を固定する —
///   最短経路の slerp を毎フレーム解き直すと、顔の yaw が 0 付近で揺れただけで経路が
///   反対側へ乗り換わり、音場が 180° 近く跳ぶ。
///
/// 真後ろでは、Euler 角の yaw が +π と -π のどちらにもなる（同じ向き）。負の側から
/// 回り込むと、着いたフレームで -177° 付近から +180° へ表記が変わる。AVAudio へは
/// 角度のまま渡すだけなので向きは連続しているが、Euler 角のまま補間・平滑化する
/// 消費者を足すときは、この表記の入れ替わりで 360° 近く掃引しないよう注意する。
public struct FacingAwayTurn: Sendable {
  private let turnAway: Double
  private let turnBack: Double
  private let ambiguousYaw: Double
  /// 0 が回っていない、1 が真後ろ。出力にはこれを smoothstep に通して使う。
  private var progress = 0.0
  /// 通る側。+1 は正の yaw 側（真後ろ = yaw +π）、-1 は負の側。
  private var side = 1.0

  /// - Parameters:
  ///   - turnAway: 真後ろへ回りきるまでの秒数。
  ///   - turnBack: 後ろ向きでなくなってから（顔が戻った・誰もいなくなった）、真後ろから
  ///     土台へ戻りきるまでの秒数。顔が戻ったらすぐ追跡へ戻したいので、回り込みより短い。
  ///   - ambiguousYaw: これ未満の |yaw|（ラジアン）は、回る側の手掛かりにしない。
  public init(turnAway: Double = 0.8, turnBack: Double = 0.6, ambiguousYaw: Double = .pi / 18) {
    self.turnAway = max(0.001, turnAway)
    self.turnBack = max(0.001, turnBack)
    self.ambiguousYaw = max(0, ambiguousYaw)
  }

  /// 回っていない（出力は土台そのまま）。
  public var isAtRest: Bool { progress <= 0 }

  /// 1フレームぶん進める。
  /// - Parameters:
  ///   - base: 土台の向き（追跡値、またはロスト時に正面へ戻りつつある向き）。
  ///   - lastTracked: 最後に追跡していた（較正後の）向き。回る側を決める手掛かり。
  ///   - isFacingAway: いま後ろ向きか。
  public mutating func advance(
    base: Rotation, lastTracked: Rotation, isFacingAway: Bool, dt: Double
  ) -> Rotation {
    let step = max(0, dt)
    if isFacingAway {
      if progress <= 0 {
        side = decidedSide(for: lastTracked) ?? 1
      }
      progress = min(1, progress + step / turnAway)
    } else if progress > 0 {
      if progress >= 1, let returning = decidedSide(for: lastTracked) {
        side = returning
      }
      progress = max(0, progress - step / turnBack)
    }
    guard progress > 0 else { return base }
    return Self.turn(from: base, side: side, fraction: Self.smoothstep(progress))
  }

  /// 回る側の手掛かり。正面に近すぎる向きは手掛かりにならないので nil。
  private func decidedSide(for rotation: Rotation) -> Double? {
    let yaw = rotation.eulerAngles.yaw
    guard abs(yaw) >= ambiguousYaw else { return nil }
    return yaw > 0 ? 1 : -1
  }

  /// 動き出しと止まり際をなだらかにする（180° 近い振りを等速で始めて止めない）。
  private static func smoothstep(_ t: Double) -> Double {
    t * t * (3 - 2 * t)
  }

  /// `base` から真後ろ（yaw = side·π）へ、`side` の側を通って補間する。
  ///
  /// `Rotation.slerp` は近い半球へ揃える（最短経路）ので、側を指定できない。ここでは
  /// 出発点を回転角 π 以下の表現（実部 ≥ 0）に揃えたうえで、終点の表現を side で選び、
  /// 半球を揃えずに補間する。単位クォータニオンの大円上を出発点から終点へ単調に進むので、
  /// yaw は side の側を通って ±π に着く。
  static func turn(from base: Rotation, side: Double, fraction: Double) -> Rotation {
    var from = base.quaternion.vector
    if from.w < 0 {
      from = -from
    }
    // 虚部 (x, y, z)・実部 w の順。y 軸まわり ±π の回転。
    let to = SIMD4<Double>(0, side, 0, 0)
    let cosine = min(1, max(-1, simd_dot(from, to)))
    let angle = acos(cosine)
    let sine = sin(angle)
    // 角が 0（もう真後ろ）か π（反対の表現の真後ろ = 同じ向き）なら、補間するまでもない。
    guard sine > 1e-9 else { return Rotation(quaternion: simd_quatd(vector: to)) }
    let t = min(max(fraction, 0), 1)
    let blended = (sin((1 - t) * angle) / sine) * from + (sin(t * angle) / sine) * to
    return Rotation(quaternion: simd_quatd(vector: blended))
  }
}
