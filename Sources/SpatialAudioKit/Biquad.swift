import Foundation

/// 2次のIIRフィルタ（biquad）。クロスオーバーの構成要素。RBJ の設計式で係数を作る。
///
/// 状態（過去サンプル）を持つので、ブロックをまたいで同じインスタンスを使い続けること。
/// 値型だが、コピーすると状態も複製される点に注意（別ストリームには別インスタンスを使う）。
public struct Biquad: Sendable {
  // a0 で正規化済みの係数。
  public let b0: Float
  public let b1: Float
  public let b2: Float
  public let a1: Float
  public let a2: Float

  // Direct Form I の状態。
  private var x1: Float = 0
  private var x2: Float = 0
  private var y1: Float = 0
  private var y2: Float = 0

  public init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
    self.b0 = b0 / a0
    self.b1 = b1 / a0
    self.b2 = b2 / a0
    self.a1 = a1 / a0
    self.a2 = a2 / a0
  }

  public mutating func process(_ x: Float) -> Float {
    let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2 = x1
    x1 = x
    y2 = y1
    y1 = y
    return y
  }

  public mutating func process(_ input: [Float]) -> [Float] {
    var output = [Float]()
    output.reserveCapacity(input.count)
    for sample in input {
      output.append(process(sample))
    }
    return output
  }

  public mutating func reset() {
    x1 = 0
    x2 = 0
    y1 = 0
    y2 = 0
  }
}

extension Biquad {
  /// RBJ ローパス。既定 Q=1/√2（バターワース）。
  public static func lowpass(
    cutoff: Double, sampleRate: Double, q: Double = 0.707_106_78
  ) -> Biquad {
    let w0 = 2 * Double.pi * cutoff / sampleRate
    let cosw = cos(w0)
    let alpha = sin(w0) / (2 * q)
    let b1 = 1 - cosw
    return Biquad(
      b0: Float(b1 / 2), b1: Float(b1), b2: Float(b1 / 2),
      a0: Float(1 + alpha), a1: Float(-2 * cosw), a2: Float(1 - alpha)
    )
  }

  /// RBJ ハイパス。既定 Q=1/√2（バターワース）。
  public static func highpass(
    cutoff: Double, sampleRate: Double, q: Double = 0.707_106_78
  ) -> Biquad {
    let w0 = 2 * Double.pi * cutoff / sampleRate
    let cosw = cos(w0)
    let alpha = sin(w0) / (2 * q)
    let b1 = -(1 + cosw)
    return Biquad(
      b0: Float((1 + cosw) / 2), b1: Float(b1), b2: Float((1 + cosw) / 2),
      a0: Float(1 + alpha), a1: Float(-2 * cosw), a2: Float(1 - alpha)
    )
  }
}
