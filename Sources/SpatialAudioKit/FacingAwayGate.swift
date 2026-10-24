import Foundation

/// 顔の見えないフレームの「後ろ向き」判定を、時間方向に均して切り替えにする。
///
/// 体の点はフレームごとに揺れるので、1フレームの判定で音場を真後ろへ回すと前後に
/// 点滅する。入りにくく・出にくくする:
///
/// - **入る**: 後ろ向きのフレームが `enterAfter` 秒、途切れずに続いてから。判定不能が
///   1フレームでも挟まれば数え直す — 誤って後ろへ回すほうが、回し損ねて正面へ戻す
///   （従来の挙動）より害が大きい。待つ間は見失いとして扱う。
/// - **出る（顔）**: 回転の取れた顔が戻ったら即座に追跡へ。
/// - **出る（判定不能）**: 後ろ向きの根拠の無いフレーム（誰もいない・判定できない・顔は
///   見えたが姿勢角が無い）が `releaseAfter` 秒続いてから見失いへ。後ろ向きの
///   フレームが挟まれば数え直す。
public struct FacingAwayGate: Sendable {
  public enum Mode: Sendable, Equatable {
    /// 顔を追っている。
    case tracking
    /// 顔が見えず、後ろ向きとも言えない。音場は正面へ戻す。
    case lost
    /// 後ろを向いている。音場は真後ろへ回す。
    case facingAway
  }

  /// フレーム時刻の差の積み上げで比べるので、浮動小数の丸めで1フレーム遅れないための余裕。
  private static let tolerance = 1e-9

  private let enterAfter: Double
  private let releaseAfter: Double
  private var awayFor = 0.0
  private var unsupportedFor = 0.0

  /// 作りたては、まだ顔を見ていないので見失い。
  public private(set) var mode: Mode = .lost

  /// - Parameters:
  ///   - enterAfter: 後ろ向きがこの秒数続いたら切り替える。
  ///   - releaseAfter: 後ろ向きの間、根拠の無いフレームがこの秒数続いたら解除する。
  public init(enterAfter: Double = 0.4, releaseAfter: Double = 1.0) {
    self.enterAfter = max(0, enterAfter)
    self.releaseAfter = max(0, releaseAfter)
  }

  /// 1フレームぶん進め、そのフレームの後のモードを返す。
  public mutating func update(with sample: HeadPoseSample, dt: Double) -> Mode {
    let step = max(0, dt)
    if sample.rotation != nil {
      awayFor = 0
      unsupportedFor = 0
      mode = .tracking
    } else if sample.presence == .facingAway {
      unsupportedFor = 0
      awayFor += step
      if mode != .facingAway {
        mode = awayFor + Self.tolerance >= enterAfter ? .facingAway : .lost
      }
    } else {
      awayFor = 0
      if mode == .facingAway {
        unsupportedFor += step
        if unsupportedFor + Self.tolerance >= releaseAfter {
          unsupportedFor = 0
          mode = .lost
        }
      } else {
        mode = .lost
      }
    }
    return mode
  }
}
