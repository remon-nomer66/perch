import AVFoundation

public enum SpatialAudioGraphError: Error, Equatable {
  case unsupportedFormat(sampleRate: Double)
}

/// AVAudioEngine と AVAudioEnvironmentNode で、モノ×2（左右の仮想スピーカー）を
/// HRTF 空間化する描画グラフ。
///
/// 頭の向きは `updateListener(_:)` → `listenerAngularOrientation` で反映する
/// （フェーズ2のカメラ由来の値も同じ経路に流す）。オーディオ出力を伴うため、
/// 発音そのものは実機でのみ確認でき、CI/ヘッドレス環境ではグラフ構成のコンパイル
/// 検証までとなる。
///
/// `scheduleBuffer` と 3D ミキシングのプロパティ設定は任意スレッドから呼べる
/// （AVAudioEngine が保証）ため、ライブ供給（タップのオーディオスレッドから
/// `schedule`、メインから `updateListener`）を許すべく `@unchecked Sendable` とする。
public final class SpatialAudioGraph: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let environment = AVAudioEnvironmentNode()
  private let playerLeft = AVAudioPlayerNode()
  private let playerRight = AVAudioPlayerNode()
  private let monoFormat: AVAudioFormat

  public init(sampleRate: Double = 48_000) throws {
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw SpatialAudioGraphError.unsupportedFormat(sampleRate: sampleRate)
    }
    monoFormat = mono

    engine.attach(environment)
    engine.attach(playerLeft)
    engine.attach(playerRight)

    // モノの点音源として環境ノードへ。HRTF はモノ入力のみ空間化する。
    engine.connect(playerLeft, to: environment, format: monoFormat)
    engine.connect(playerRight, to: environment, format: monoFormat)
    // 環境ノードの出力（ヘッドホン向けバイノーラル）をメインミキサ経由で出力へ。
    engine.connect(environment, to: engine.mainMixerNode, format: nil)

    // ヘッドホン前提でバイノーラル化する。
    environment.outputType = .headphones
    environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environment.listenerAngularOrientation = ListenerOrientation.forward.audioOrientation
  }

  /// 設定を反映する。左右スピーカーの位置とレンダリング品質を更新する。
  public func apply(_ parameters: SpatialAudioParameters) {
    let algorithm = parameters.quality.audioAlgorithm
    playerLeft.renderingAlgorithm = algorithm
    playerRight.renderingAlgorithm = algorithm
    playerLeft.position = parameters.field.left.audioPoint
    playerRight.position = parameters.field.right.audioPoint
  }

  /// リスナー（頭）の向きを更新する。頭部追従はここへ値を流す。
  public func updateListener(_ orientation: ListenerOrientation) {
    environment.listenerAngularOrientation = orientation.audioOrientation
  }

  public func start() throws {
    engine.prepare()
    try engine.start()
    playerLeft.play()
    playerRight.play()
  }

  public func stop() {
    playerLeft.stop()
    playerRight.stop()
    engine.stop()
  }

  /// 左右それぞれのモノバッファをループ再生としてスケジュールする（デモ用）。
  public func scheduleLooping(left: AVAudioPCMBuffer, right: AVAudioPCMBuffer) {
    playerLeft.scheduleBuffer(left, at: nil, options: .loops, completionHandler: nil)
    playerRight.scheduleBuffer(right, at: nil, options: .loops, completionHandler: nil)
  }

  /// 左右のモノバッファを1回ぶんスケジュールする（ライブ供給用）。同じ長さの
  /// L/R を対で渡すことで、両プレイヤーが同じクロックで同期再生される。
  public func schedule(left: AVAudioPCMBuffer, right: AVAudioPCMBuffer) {
    playerLeft.scheduleBuffer(left, completionHandler: nil)
    playerRight.scheduleBuffer(right, completionHandler: nil)
  }

  /// モノの Float サンプル列から、このグラフの形式のバッファを作る。
  public func makeMonoBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: monoFormat,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress {
        channel.update(from: base, count: samples.count)
      }
    }
    return buffer
  }
}
