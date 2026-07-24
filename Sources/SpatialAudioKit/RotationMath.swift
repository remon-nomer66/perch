import Foundation
import simd

/// 頭の向き1つぶんの回転。クォータニオンで持ち、合成・差分・補間もクォータニオンで行う。
///
/// yaw/pitch/roll を成分ごとに引き算・平均すると回転として正しくなく、軸が結合したときや
/// 角度境界で不連続になる。そのため中心化（基準姿勢との差分）・平均・スムージングはすべて
/// この型の上で行い、Euler 角への変換は AVAudio 境界（`listenerOrientation`）でのみ行う。
public struct Rotation: Sendable, Equatable {
  public var quaternion: simd_quatd

  public init(quaternion: simd_quatd) {
    self.quaternion = simd_normalize(quaternion)
  }

  /// yaw(Y軸)→pitch(X軸)→roll(Z軸) の順で合成した回転。単位ラジアン。
  /// 軸は右手系: x 右、y 上、z 手前（リスナーは -z を向く）。
  public init(yaw: Double, pitch: Double, roll: Double) {
    let yawTurn = simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0))
    let pitchTurn = simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
    let rollTurn = simd_quatd(angle: roll, axis: SIMD3(0, 0, 1))
    self.init(quaternion: yawTurn * pitchTurn * rollTurn)
  }

  public static let identity = Rotation(quaternion: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))

  public var inverse: Rotation { Rotation(quaternion: quaternion.inverse) }

  public static func * (lhs: Rotation, rhs: Rotation) -> Rotation {
    Rotation(quaternion: lhs.quaternion * rhs.quaternion)
  }

  /// もう一方の回転までの角距離（ラジアン、0…π）。q と -q は同じ回転なので絶対値を取る。
  public func angle(to other: Rotation) -> Double {
    let dot = min(1, abs(simd_dot(quaternion.vector, other.quaternion.vector)))
    return 2 * acos(dot)
  }

  /// 球面線形補間。q と -q の二重被覆で遠回りしないよう、近い側の半球へ揃えてから補間する。
  public func slerp(to other: Rotation, fraction: Double) -> Rotation {
    var target = other.quaternion
    if simd_dot(quaternion.vector, target.vector) < 0 {
      target = simd_quatd(vector: -target.vector)
    }
    let t = min(max(fraction, 0), 1)
    return Rotation(quaternion: simd_slerp(quaternion, target, t))
  }

  /// yaw(Y)→pitch(X)→roll(Z) 分解の Euler 角（ラジアン）。`init(yaw:pitch:roll:)` の逆。
  /// pitch ±90° のジンバル特異点近傍では yaw/roll の切り分けが不定になるが、
  /// 顔追跡の実用域（|pitch| < 60°）では問題にならない。
  public var eulerAngles: (yaw: Double, pitch: Double, roll: Double) {
    let m = simd_matrix3x3(quaternion)
    // R = Ry·Rx·Rz の成分から復元する。simd の行列は列優先: R[row][col] = columns.col[row]
    let sinPitch = min(1, max(-1, -m.columns.2[1]))
    let pitch = asin(sinPitch)
    let yaw = atan2(m.columns.2[0], m.columns.2[2])
    let roll = atan2(m.columns.0[1], m.columns.1[1])
    return (yaw, pitch, roll)
  }

  /// AVAudio 境界向けの表現。ここで初めて Euler 角に落とす。
  public var listenerOrientation: ListenerOrientation {
    let euler = eulerAngles
    return ListenerOrientation(yaw: euler.yaw, pitch: euler.pitch, roll: euler.roll)
  }
}

/// Vision の顔角度（`VNFaceObservation` の yaw/pitch/roll、ラジアン）をこちらの回転へ写す。
///
/// Vision の各軸の正方向・カメラのミラーリングと、音声側の軸の対応は実機スパイクで
/// 検証する（計画 P0）。それまでの仮定符号をここ1箇所に集め、実測で違ったらこの値だけを
/// 直せばよいようにしておく。
public struct VisionPoseConversion: Sendable {
  public var yawSign: Double
  public var pitchSign: Double
  public var rollSign: Double

  public init(yawSign: Double = 1, pitchSign: Double = 1, rollSign: Double = 1) {
    self.yawSign = yawSign
    self.pitchSign = pitchSign
    self.rollSign = rollSign
  }

  /// スパイクで検証するまでの仮定: yaw と pitch を反転する。Vision は「左を向くと正・
  /// うなずいて下が正」、AVAudio のリスナーはその逆向きが正、という対応（レビュー指摘）。
  /// 間違っていれば音場が固定でなく頭に付いてくるので、実機で一目で分かる。
  public static let assumed = VisionPoseConversion(yawSign: -1, pitchSign: -1, rollSign: 1)

  public func rotation(yaw: Double, pitch: Double, roll: Double) -> Rotation {
    Rotation(yaw: yaw * yawSign, pitch: pitch * pitchSign, roll: roll * rollSign)
  }
}
