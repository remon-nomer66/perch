import Foundation

/// 相対距離比（較正時=1.0）を音の距離感へ写す純粋な対応。
///
/// - **リスナー後退**: 音源は前方(-z)に固定したまま、リスナーを +z へ下げる。
///   `AVAudioEnvironmentNode` の距離減衰は音源との実距離から出るので、
///   比率2.0 ≒ 距離2倍 ≒ 約-6dB が幾何のまま得られる。
/// - **こもり**: 距離減衰からは高域の鈍りは出ないので、中高域に明示的な
///   一次ローパスを掛ける。遠いほどカットオフを下げる。
public enum DistanceRendering {
  /// 効果として意味を認める比率の範囲。これ以上は推定誤差の増幅にしかならない。
  public static let ratioRange = 0.5...3.5
  /// これ以上のカットオフは実質バイパス（掛けても聴こえない）。
  public static let bypassCutoff = 17_000.0

  static func clamped(_ ratio: Double) -> Double {
    min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
  }

  /// リスナーの後退量（メートル、+z）。較正距離ぶんを 1m と見なした相対後退。
  /// 比率1で 0、近づく側（<1）は前へ出る（負）。
  public static func listenerOffset(ratio: Double) -> Double {
    clamped(ratio) - 1
  }

  /// 距離こもりのカットオフ（Hz）。比率1で実質バイパス、遠ざかるほど二乗で暗くなる。
  public static func lowpassCutoff(ratio: Double) -> Double {
    let clamped = clamped(ratio)
    guard clamped > 1 else { return bypassCutoff }
    return max(2_000, bypassCutoff / (clamped * clamped))
  }
}

/// 一次（6dB/oct）ローパス。距離による高域の鈍りは緩やかなので、急峻な
/// フィルタより一次の方が自然で、係数更新もクリックを生まない。
/// オーディオスレッドで呼ぶ前提の軽い実装。
public struct OnePoleLowpass: Sendable {
  private var state: Float = 0

  public init() {}

  /// カットオフがバイパス域なら素通し（状態だけ追従させ、再開時のクリックを防ぐ）。
  public mutating func process(_ samples: [Float], cutoff: Double, sampleRate: Double) -> [Float] {
    guard !samples.isEmpty else { return samples }
    guard cutoff < DistanceRendering.bypassCutoff else {
      state = samples[samples.count - 1]
      return samples
    }
    let alpha = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
    var output = [Float](repeating: 0, count: samples.count)
    var current = state
    for index in 0..<samples.count {
      current += alpha * (samples[index] - current)
      output[index] = current
    }
    state = current
    return output
  }
}
