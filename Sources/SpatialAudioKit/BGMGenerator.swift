import Foundation

/// 値の合成だけで作る検証用BGM（4/4・4小節ループ Am→F→C→G）。
///
/// キック4つ打ち・スネア2/4拍・ハイハット8分・ベース8分・アルペジオ8分。
/// すべての発音が8分グリッド上にあり、テンポも既知なので、拍検出の
/// 「答え合わせ」に使える。ノイズもサンプル位置から決まる決定的なもので、
/// 同じ設定なら常に同じ波形になる。音楽ファイルも再生アプリも要らない。
public struct BGMGenerator: Sendable {
  public let bpm: Double
  public let sampleRate: Double
  private var position = 0  // 通算サンプル位置

  private let beatDuration: Double
  private let eighthDuration: Double

  /// コード進行（1小節ずつ）: ベースのルートと、8分で回すアルペジオの構成音。
  private static let bassRoots: [Double] = [55.0, 43.65, 65.41, 49.0]  // A1 F1 C2 G1
  private static let arpeggioTones: [[Double]] = [
    [110.00, 130.81, 164.81, 220.00],  // Am: A2 C3 E3 A3
    [87.31, 110.00, 130.81, 174.61],  // F:  F2 A2 C3 F3
    [130.81, 164.81, 196.00, 261.63],  // C:  C3 E3 G3 C4
    [98.00, 123.47, 146.83, 196.00],  // G:  G2 B2 D3 G3
  ]

  public init(bpm: Double = 120, sampleRate: Double = 48_000) {
    self.bpm = max(bpm, 1)
    self.sampleRate = max(sampleRate, 1)
    beatDuration = 60 / self.bpm
    eighthDuration = beatDuration / 2
  }

  /// 続きから frameCount サンプルぶんのステレオを合成する。
  public mutating func render(frameCount: Int) -> (left: [Float], right: [Float]) {
    let count = max(0, frameCount)
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    for frame in 0..<count {
      let time = Double(position) / sampleRate
      let sample = synthesize(time: time, index: position)
      left[frame] = sample.left
      right[frame] = sample.right
      position += 1
    }
    return (left, right)
  }

  private func synthesize(time: Double, index: Int) -> (left: Float, right: Float) {
    let beatIndex = Int(time / beatDuration)
    let eighthIndex = Int(time / eighthDuration)
    let bar = (beatIndex / 4) % Self.bassRoots.count
    let timeInBeat = time.truncatingRemainder(dividingBy: beatDuration)
    let timeInEighth = time.truncatingRemainder(dividingBy: eighthDuration)

    // キック（4つ打ち）: ピッチが 140→50Hz へ落ちるサイン。位相は周波数の積分。
    let kickPhase = 2 * Double.pi * (50 * timeInBeat + 2.7 * (1 - exp(-timeInBeat / 0.03)))
    let kick = sin(kickPhase) * 0.5 * exp(-timeInBeat / 0.12)

    // スネア（2・4拍目）: ノイズ + 190Hz の胴鳴り。
    var snare = 0.0
    if beatIndex % 2 == 1 {
      snare =
        Double(Self.noise(index)) * 0.35 * exp(-timeInBeat / 0.06)
        + sin(2 * Double.pi * 190 * timeInBeat) * 0.15 * exp(-timeInBeat / 0.04)
    }

    // ハイハット（8分）: ノイズの差分（高域寄り）を短く。
    let hat =
      Double(Self.noise(index) - Self.noise(index - 1)) * 0.5
      * 0.3 * exp(-timeInEighth / 0.02)

    // ベース（8分・ルート音）: 基音 + 2倍音。クリック防止に 5ms アタック。
    let root = Self.bassRoots[bar]
    let bassEnvelope = min(timeInEighth / 0.005, 1) * exp(-timeInEighth / 0.25)
    let bass =
      (sin(2 * Double.pi * root * timeInEighth)
        + 0.3 * sin(4 * Double.pi * root * timeInEighth)) * 0.26 * bassEnvelope

    // アルペジオ（8分でコードを回す）: 左右交互に振って広がりを出す。
    let tone = Self.arpeggioTones[bar][eighthIndex % 4]
    let arpeggioEnvelope = min(timeInEighth / 0.01, 1) * exp(-timeInEighth / 0.18)
    let arpeggio = sin(2 * Double.pi * tone * timeInEighth) * 0.14 * arpeggioEnvelope
    let arpeggioLeft = eighthIndex % 2 == 0 ? arpeggio * 0.85 : arpeggio * 0.35
    let arpeggioRight = eighthIndex % 2 == 0 ? arpeggio * 0.35 : arpeggio * 0.85

    let master = 0.55
    let centre = kick + snare + bass
    return (
      left: Float((centre + hat * 0.8 + arpeggioLeft) * master),
      right: Float((centre + hat * 1.0 + arpeggioRight) * master)
    )
  }

  /// サンプル位置から決まる決定的なホワイトノイズ（-1〜1）。SplitMix64 のミキサ。
  private static func noise(_ index: Int) -> Float {
    var z = UInt64(bitPattern: Int64(index)) &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Float(Double(z >> 11) * (2.0 / 9_007_199_254_740_992.0) - 1.0)
  }
}
