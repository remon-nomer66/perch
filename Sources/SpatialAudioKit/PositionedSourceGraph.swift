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
  /// HRTF を通さず、両耳へ直接流すステレオ経路（低音用）。無指向性の低域は空間化
  /// せずフルレベルで両耳に届ける方が力強い。
  private let directPlayer = AVAudioPlayerNode()
  private let monoFormat: AVAudioFormat
  private let stereoFormat: AVAudioFormat

  /// 出力構成の変化（既定出力の切替・サンプルレート変更）でエンジンが自ら止まった時に
  /// 呼ばれる。止まったエンジンは戻らないので、所有者が作り直す必要がある。放置すると
  /// タップの原音ミュートだけが生き残り、システム全体が無音のままになる。
  /// `start()` の前に設定すること（通知は任意スレッドから届く）。
  public var onConfigurationChange: (@Sendable () -> Void)?
  private var configurationObserver: (any NSObjectProtocol)?

  public init(sampleRate: Double = 48_000, sourceCount: Int) throws {
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
    else {
      throw SpatialAudioGraphError.unsupportedFormat(sampleRate: sampleRate)
    }
    monoFormat = mono
    stereoFormat = stereo
    players = (0..<max(1, sourceCount)).map { _ in AVAudioPlayerNode() }

    engine.attach(environment)
    for player in players {
      engine.attach(player)
      engine.connect(player, to: environment, format: monoFormat)
    }
    engine.connect(environment, to: engine.mainMixerNode, format: nil)

    // 低音の直通路: 環境ノード（HRTF）を経由せず直接ミキサへ。
    engine.attach(directPlayer)
    engine.connect(directPlayer, to: engine.mainMixerNode, format: stereoFormat)

    environment.outputType = .headphones
    environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environment.listenerAngularOrientation = ListenerOrientation.forward.audioOrientation

    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.onConfigurationChange?()
    }
  }

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
  }

  public var sourceCount: Int { players.count }

  /// テストが構成変更通知を差し込むための内部フック（通知は object 一致で届くため）。
  var engineForNotifications: AVAudioEngine { engine }

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

  /// リスナーを前後に動かす。+z が後退（前方 -z の音源から遠ざかる）。距離連動用。
  public func setListenerZ(_ z: Double) {
    environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: Float(z))
  }

  public func start() throws {
    engine.prepare()
    try engine.start()
    for player in players { player.play() }
    directPlayer.play()
  }

  public func stop() {
    for player in players { player.stop() }
    directPlayer.stop()
    engine.stop()
  }

  public func schedule(index: Int, buffer: AVAudioPCMBuffer) {
    guard players.indices.contains(index) else { return }
    players[index].scheduleBuffer(buffer, completionHandler: nil)
  }

  /// HRTF を通さない直通路（低音）へステレオバッファをスケジュールする。
  public func scheduleDirect(buffer: AVAudioPCMBuffer) {
    directPlayer.scheduleBuffer(buffer, completionHandler: nil)
  }

  /// 全体の出力音量（メイクアップゲイン）。
  public func setOutputVolume(_ volume: Float) {
    engine.mainMixerNode.outputVolume = volume
  }

  /// 左右のモノ列から2chステレオバッファを作る（直通路用）。
  public func makeStereoBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer? {
    let count = min(left.count, right.count)
    guard count > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: stereoFormat,
        frameCapacity: AVAudioFrameCount(count)
      ),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(count)
    for index in 0..<count {
      channels[0][index] = left[index]
      channels[1][index] = right[index]
    }
    return buffer
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
