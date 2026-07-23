import Foundation

/// ステレオ2chを空間化するときの、左右の仮想スピーカー配置。
///
/// AVAudioEnvironmentNode はモノラル入力しか空間化しない（ステレオは素通し）。
/// そこで L/R を2つのモノ音源として、正面から左右に開いた位置に置く。
/// `spread` は中央から各スピーカーまでの開き角。`elevation` は音場全体の上下の傾き。
///
/// 上下（`elevation`）は汎用HRTFでは横方向ほど強くは効かない（上下の定位は個人の
/// 耳の形に依存するため）。さらに低域は無指向性なので、上下に振っても“下”には
/// 聞こえない。迫力ある低音は方向ではなく量感で作るのが筋で、上下の空間化が意味を
/// 持つのは中高域。将来の周波数分割空間化で、低域は中央固定・中高域のみ上下させる。
public struct StereoField: Equatable, Sendable {
  /// 中央から左右各スピーカーまでの開き角。ラジアン。0〜π/2 に収める。
  public let spread: Double
  /// 音場全体の上下の傾き。水平が 0、上が正。ラジアン。-π/2〜π/2 に収める。
  public let elevation: Double
  /// 仮想スピーカーまでの距離。メートル。
  public let distance: Double

  /// 既定の開き角 30°。ステレオスピーカーの標準的な配置に倣う。
  public static let defaultSpread = Double.pi / 6

  public init(
    spread: Double = defaultSpread,
    elevation: Double = 0,
    distance: Double = 1.0
  ) {
    // 開き角は 0（正面に重なる）〜π/2（真横）に収める。範囲外の入力を
    // もっともらしい既定値に化かさず、意味のある端に丸める。
    self.spread = min(max(0, spread), .pi / 2)
    // 仰角は真下（-π/2）〜真上（π/2）に収める。
    self.elevation = min(max(-.pi / 2, elevation), .pi / 2)
    self.distance = max(0, distance)
  }

  /// 左スピーカーの方向。中央から左へ `spread` だけ振り、`elevation` だけ上下する。
  public var left: SphericalDirection {
    SphericalDirection(azimuth: -spread, elevation: elevation, distance: distance)
  }

  /// 右スピーカーの方向。中央から右へ `spread` だけ振り、`elevation` だけ上下する。
  public var right: SphericalDirection {
    SphericalDirection(azimuth: spread, elevation: elevation, distance: distance)
  }
}
