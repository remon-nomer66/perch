import Foundation

/// 発音確認用の単純な正弦波を生成する。描画経路が実際に鳴るかを、権限の要らない
/// トーンで確かめるための最小の音源。実運用の音声は Core Audio Tap から供給する。
public enum ToneGenerator {
  /// `frameCount` サンプルぶんの正弦波（モノ）を返す。振幅は 0〜1。
  ///
  /// ループ再生でプチノイズを避けたい場合は、呼び出し側で整数周期ぶんの長さを選ぶ。
  public static func sine(
    frequency: Double,
    sampleRate: Double,
    frameCount: Int,
    amplitude: Double = 0.2
  ) -> [Float] {
    guard frameCount > 0, sampleRate > 0, frequency > 0 else { return [] }
    let radiansPerSample = 2 * Double.pi * frequency / sampleRate
    return (0..<frameCount).map { index in
      Float(amplitude * sin(radiansPerSample * Double(index)))
    }
  }
}
