import Accelerate
import Foundation

/// フレームを Hann 窓 + 実数 DFT にかけ、正規化した振幅スペクトルを返す。
///
/// vDSP の実数 DFT（zrop）を使う。出力はビン 0（DC）〜 size/2−1 の振幅で、
/// 振幅1のサイン入力がおよそ 0.5 になるよう 1/size で正規化する（Hann 窓の利得込み）。
/// 作業バッファを使い回すため、1インスタンスは単一スレッドから使うこと。
public final class SpectrumAnalyzer {
  public let size: Int
  public var binCount: Int { size / 2 }

  private let setup: vDSP_DFT_Setup
  private let window: [Float]
  private var windowed: [Float]
  private var inputReal: [Float]
  private var inputImaginary: [Float]
  private var outputReal: [Float]
  private var outputImaginary: [Float]

  /// size は 64 以上の 2 の冪。満たさなければ作れない。
  public init?(size: Int) {
    guard size >= 64, size & (size - 1) == 0,
      let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
    else { return nil }
    self.size = size
    self.setup = setup

    var hann = [Float](repeating: 0, count: size)
    vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    window = hann

    let half = size / 2
    windowed = [Float](repeating: 0, count: size)
    inputReal = [Float](repeating: 0, count: half)
    inputImaginary = [Float](repeating: 0, count: half)
    outputReal = [Float](repeating: 0, count: half)
    outputImaginary = [Float](repeating: 0, count: half)
  }

  deinit {
    vDSP_DFT_DestroySetup(setup)
  }

  /// 長さ size のフレームの振幅スペクトル（binCount 個）。長さ違いは空を返す。
  public func magnitudes(_ frame: [Float]) -> [Float] {
    guard frame.count == size else { return [] }
    vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))

    // 実数 DFT の入力詰め: 偶数番を実部、奇数番を虚部に分ける。
    let half = size / 2
    for index in 0..<half {
      inputReal[index] = windowed[2 * index]
      inputImaginary[index] = windowed[2 * index + 1]
    }
    vDSP_DFT_Execute(setup, inputReal, inputImaginary, &outputReal, &outputImaginary)

    // 出力詰め: outputReal[0] が DC、outputImaginary[0] はナイキスト成分なので混ぜない。
    var result = [Float](repeating: 0, count: half)
    let scale = 1 / Float(size)
    result[0] = abs(outputReal[0]) * scale
    for bin in 1..<half {
      let real = outputReal[bin]
      let imaginary = outputImaginary[bin]
      result[bin] = (real * real + imaginary * imaginary).squareRoot() * scale
    }
    return result
  }
}
