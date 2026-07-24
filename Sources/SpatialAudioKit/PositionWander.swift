import Foundation

/// 音源の位置を、誤差レベルでゆっくり漂わせる揺らぎ。
///
/// 完全静止よりも、わずかに動く音の方が「頭の外に出た」感じ（外在化）が強まり、
/// 自然で生っぽくなる。ビリビリ震えないよう、遅い正弦波（LFO）を複数重ねた滑らかな
/// ドリフトにする。音源ごとに位相をずらし、揃って動かないようにする。
public struct PositionWander: Sendable {
  /// 方位角の最大振れ幅（ラジアン）。仰角はこの半分。0 なら揺らぎ無し。
  public let amplitude: Double

  public init(degrees: Double) {
    amplitude = max(0, degrees) * .pi / 180
  }

  /// 音源 `source` の時刻 `time`（秒）での方位・仰角のオフセット（ラジアン）。
  public func offset(source: Int, time: Double) -> (azimuth: Double, elevation: Double) {
    guard amplitude > 0 else { return (0, 0) }
    let phase = Double(source)
    // 係数 0.6+0.4=1.0 なので、合成しても ±amplitude を超えない。
    let azimuth = amplitude * (
      0.6 * sin(2 * .pi * 0.07 * time + phase * 1.7)
        + 0.4 * sin(2 * .pi * 0.13 * time + phase * 2.9)
    )
    let elevation = amplitude * 0.5 * (
      0.6 * sin(2 * .pi * 0.05 * time + phase * 2.3)
        + 0.4 * sin(2 * .pi * 0.11 * time + phase * 0.8)
    )
    return (azimuth, elevation)
  }

  /// テンポ同期版: 位相を秒ではなく拍数 `beats` で刻む。2小節（8拍）で1往復の
  /// 主揺らぎに、8小節（32拍）のゆったりした副揺らぎを重ねる。フレーズと同じ周期で
  /// 漂うのでテンポに乗って聞こえ、かつ角速度が緩やかでジッパーノイズを出さない。
  public func offset(source: Int, beats: Double) -> (azimuth: Double, elevation: Double) {
    guard amplitude > 0 else { return (0, 0) }
    let phase = Double(source)
    let azimuth = amplitude * (
      0.6 * sin(2 * .pi * beats / 8 + phase * 1.7)
        + 0.4 * sin(2 * .pi * beats / 32 + phase * 2.9)
    )
    let elevation = amplitude * 0.5 * (
      0.6 * sin(2 * .pi * beats / 16 + phase * 2.3)
        + 0.4 * sin(2 * .pi * beats / 32 + phase * 0.8)
    )
    return (azimuth, elevation)
  }
}
