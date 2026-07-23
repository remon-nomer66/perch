import Foundation

/// 音源の方向と距離。リスナーを原点とした極座標で表す。
///
/// 角度はラジアンで持つ。頭の向きを与えるセンサー（フェーズ2の Vision 顔向き等）が
/// ラジアンで値を出すため、単位変換を境界の1か所に閉じ込める狙い。
/// AVAudioEnvironmentNode が要求する直交座標・度への変換は描画層の責務とし、
/// この型はフレームワークに依存しない。
public struct SphericalDirection: Equatable, Sendable {
  /// 水平角。正面が 0、右向きが正（上から見て時計回り）。単位ラジアン。
  public let azimuth: Double
  /// 仰角。水平が 0、上が正。単位ラジアン。
  public let elevation: Double
  /// リスナーからの距離。メートル。物理的に負はありえないため 0 未満は 0 に丸める。
  public let distance: Double

  public init(azimuth: Double, elevation: Double, distance: Double) {
    self.azimuth = azimuth
    self.elevation = elevation
    self.distance = max(0, distance)
  }

  /// 直交座標へ変換する。右手系で、正面 = -Z、右 = +X、上 = +Y。
  ///
  /// この軸の割り当ては数学上の約束にすぎない。AVAudioEnvironmentNode の実際の軸
  /// （Apple のサンプルには +Z をリスナー側に取る流儀もある）と一致するかは、
  /// 統合時に実機で音の左右を確かめて決める。
  public var cartesian: (x: Double, y: Double, z: Double) {
    let horizontal = distance * cos(elevation)
    return (
      x: horizontal * sin(azimuth),
      y: distance * sin(elevation),
      z: -horizontal * cos(azimuth)
    )
  }
}
