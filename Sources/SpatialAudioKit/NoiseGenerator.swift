import Foundation

/// 発音確認用の広帯域（白色）ノイズを生成する。
///
/// HRTF の前後・上下の定位は、単一周波数のトーンよりも広帯域信号の方がはるかに
/// はっきりする（耳介による周波数の谷が前後を分ける手がかりになるため）。前後が
/// 「正面か後頭部か」を耳で判定したいときは、トーンではなくこちらを使う。
///
/// 決定論的な疑似乱数（xorshift64）で作るので、ループ再生でも毎回同じ波形になる。
public enum NoiseGenerator {
  public static func white(
    frameCount: Int,
    amplitude: Double = 0.2,
    seed: UInt64 = 0x2545_F491_4F6C_DD1D
  ) -> [Float] {
    guard frameCount > 0 else { return [] }
    // 種が 0 だと xorshift は 0 に張り付くので、非ゼロの既定へ逃がす。
    var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    func nextUnitInterval() -> Double {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      // 上位 53 ビットを [0,1) の Double にする。
      return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
    return (0..<frameCount).map { _ in
      Float(amplitude * (nextUnitInterval() * 2 - 1))
    }
  }
}
