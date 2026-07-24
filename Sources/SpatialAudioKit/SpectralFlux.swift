import Foundation

/// スペクトルフラックス（スペクトルの「増えた分」）の純関数群。
///
/// 音の立ち上がり（onset）は、どこかの周波数帯のエネルギーが急に増える瞬間として
/// 現れる。低音エネルギーだけを見るより、全ビンの増分を合計する方がスネアや
/// ボーカルの立ち上がりも拾える（librosa/Essentia の onset 検出と同系の考え方）。
public enum SpectralFlux {
  /// 対数圧縮 log1p(gamma·x)。小さい音の立ち上がりを持ち上げ、音量差への依存を抑える。
  public static func logCompressed(_ magnitudes: [Float], gamma: Float = 100) -> [Float] {
    magnitudes.map { log1p(max($0, 0) * gamma) }
  }

  /// 半波整流スペクトルフラックス: 前フレームから「増えた分」だけをビン平均する。
  /// 減った分は音の終わりであって立ち上がりではないので数えない。
  /// DC（ビン0）は立ち上がりの情報を持たないので除外。長さが違えば共通部分を使う。
  public static func flux(previous: [Float], current: [Float]) -> Double {
    let count = min(previous.count, current.count)
    guard count > 1 else { return 0 }
    var sum = 0.0
    for bin in 1..<count {
      let difference = Double(current[bin]) - Double(previous[bin])
      if difference > 0 { sum += difference }
    }
    return sum / Double(count - 1)
  }
}
