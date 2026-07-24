import Foundation

/// リスナー（頭）の向き。yaw / pitch / roll をラジアンで持つ。
///
/// フェーズ1では常に `.forward`（正面固定）で使う。フェーズ2でカメラ由来の顔向きを
/// ここへ流し込み、音場を空間に固定する（頭を回すと音源が相対的に反対へ動く）。
/// センサーがラジアンで値を出すためラジアンで保持し、AVAudio3DAngularOrientation が
/// 要求する度への変換は境界（`degrees`）でのみ行う。
public struct ListenerOrientation: Equatable, Sendable {
  /// 水平回転。単位ラジアン、範囲 [-π, π]。
  public let yaw: Double
  /// 上下回転。単位ラジアン、範囲 [-π, π]。
  public let pitch: Double
  /// 傾き。単位ラジアン、範囲 [-π, π]。
  public let roll: Double

  public init(yaw: Double, pitch: Double, roll: Double) {
    self.yaw = ListenerOrientation.wrapped(yaw)
    self.pitch = ListenerOrientation.wrapped(pitch)
    self.roll = ListenerOrientation.wrapped(roll)
  }

  /// 正面。回転なし。フェーズ1の固定値。
  public static let forward = ListenerOrientation(yaw: 0, pitch: 0, roll: 0)

  /// 角度を [-π, π] に正規化する。センサーやフィルタが範囲外の値を出しても、
  /// 音の向きが不連続に飛ばないよう1周ぶんを畳み込む。
  static func wrapped(_ angle: Double) -> Double {
    angle.remainder(dividingBy: 2 * .pi)
  }

  /// 度に変換した (yaw, pitch, roll)。AVAudio3DAngularOrientation は度で受け取る。
  public var degrees: (yaw: Double, pitch: Double, roll: Double) {
    let toDegrees = 180 / Double.pi
    return (yaw: yaw * toDegrees, pitch: pitch * toDegrees, roll: roll * toDegrees)
  }
}
