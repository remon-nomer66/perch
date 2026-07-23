import AVFoundation

/// N個の位置付きモノ音源を AVAudioEnvironmentNode で HRTF 空間化する汎用グラフ。
///
/// マルチバンド/M-S のように、複数の点音源を別々の位置へ置く用途に使う。各音源に
/// 同じ長さのバッファを対でスケジュールすれば、全音源が同じクロックで同期再生される。
/// `scheduleBuffer` と 3D プロパティ設定は任意スレッドから呼べる（AVAudioEngine 保証）
/// ため `@unchecked Sendable`。発音は実機でのみ確認できる。
public final class PositionedSourceGraph: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let environment = AVAudioEnvironmentNode()
  private let players: [AVAudioPlayerNode]
  private let monoFormat: AVAudioFormat

  public init(sampleRate: Double = 48_000, sourceCount: Int) throws {
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw SpatialAudioGraphError.unsupportedFormat(sampleRate: sampleRate)
    }
    monoFormat = mono
    players = (0..<max(1, sourceCount)).map { _ in AVAudioPlayerNode() }

    engine.attach(environment)
    for player in players {
      engine.attach(player)
      engine.connect(player, to: environment, format: monoFormat)
    }
    engine.connect(environment, to: engine.mainMixerNode, format: nil)

    environment.outputType = .headphones
    environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environment.listenerAngularOrientation = ListenerOrientation.forward.audioOrientation
  }

  public var sourceCount: Int { players.count }

  public func setAlgorithm(_ quality: SpatialRenderingQuality) {
    for player in players {
      player.renderingAlgorithm = quality.audioAlgorithm
    }
  }

  public func setPosition(_ index: Int, _ direction: SphericalDirection) {
    guard players.indices.contains(index) else { return }
    players[index].position = direction.audioPoint
  }

  public func updateListener(_ orientation: ListenerOrientation) {
    environment.listenerAngularOrientation = orientation.audioOrientation
  }

  public func start() throws {
    engine.prepare()
    try engine.start()
    for player in players { player.play() }
  }

  public func stop() {
    for player in players { player.stop() }
    engine.stop()
  }

  public func schedule(index: Int, buffer: AVAudioPCMBuffer) {
    guard players.indices.contains(index) else { return }
    players[index].scheduleBuffer(buffer, completionHandler: nil)
  }

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
