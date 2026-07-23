import Foundation

/// ステレオ2chを空間化するときの、左右の仮想スピーカー配置。
///
/// AVAudioEnvironmentNode はモノラル入力しか空間化しない（ステレオは素通し）。
/// そこで L/R を2つのモノ音源として、正面から左右に開いた位置に置く。
/// `spread` は中央から各スピーカーまでの開き角。狭いほど音像は前方に集まり、
/// 広いほど左右に開く。
public struct StereoField: Equatable, Sendable {
  /// 中央から左右各スピーカーまでの開き角。ラジアン。0〜π/2 に収める。
  public let spread: Double
  /// 仮想スピーカーまでの距離。メートル。
  public let distance: Double

  /// 既定の開き角 30°。ステレオスピーカーの標準的な配置に倣う。
  public static let defaultSpread = Double.pi / 6

  public init(spread: Double = defaultSpread, distance: Double = 1.0) {
    // 開き角は 0（正面に重なる）〜π/2（真横）に収める。範囲外の入力を
    // もっともらしい既定値に化かさず、意味のある端に丸める。
    self.spread = min(max(0, spread), .pi / 2)
    self.distance = max(0, distance)
  }

  /// 左スピーカーの方向。中央から左へ `spread` だけ振る。
  public var left: SphericalDirection {
    SphericalDirection(azimuth: -spread, elevation: 0, distance: distance)
  }

  /// 右スピーカーの方向。中央から右へ `spread` だけ振る。
  public var right: SphericalDirection {
    SphericalDirection(azimuth: spread, elevation: 0, distance: distance)
  }
}
