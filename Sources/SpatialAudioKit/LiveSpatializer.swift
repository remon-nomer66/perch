import AVFoundation
import CoreAudio

/// システム音のリアルタイム空間化。`SystemAudioTap` で取得した音を `SpatialAudioGraph`
/// に流し込み、HRTF 空間化して出力する。
///
/// タップのIOProc（オーディオスレッド）で取得ブロックを L/R のモノバッファに分け、
/// プレイヤーへスケジュールする。原音はミュートし、自プロセスは除外する（空間化版だけを
/// 鳴らし、フィードバックを防ぐ）。発音は実機でのみ確認でき、この段階はコンパイル検証まで。
/// バッファ長・ドリフト・レイテンシは実機での調整対象。
@available(macOS 14.4, *)
public final class LiveSpatializer: @unchecked Sendable {
  private let graph: SpatialAudioGraph
  private let muteOriginal: Bool
  private var tap: SystemAudioTap?

  /// - Parameters:
  ///   - parameters: 空間化の初期設定。
  ///   - muteOriginal: 原音を消して空間化版だけを流すか。A/B したいときは false。
  ///   - sampleRate: グラフの標本化周波数。タップは通常 48kHz。ずれると速度が変わる。
  public init(
    parameters: SpatialAudioParameters = SpatialAudioParameters(isEnabled: true, quality: .high),
    muteOriginal: Bool = true,
    sampleRate: Double = 48_000
  ) throws {
    graph = try SpatialAudioGraph(sampleRate: sampleRate)
    graph.apply(parameters)
    self.muteOriginal = muteOriginal
  }

  public func start() throws {
    try graph.start()

    let graph = self.graph
    let newTap = SystemAudioTap(muteOriginal: muteOriginal, excludeCurrentProcess: true) { bufferListPointer in
      let (left, right) = LiveSpatializer.extractStereo(bufferListPointer)
      guard !left.isEmpty,
        let leftBuffer = graph.makeMonoBuffer(left),
        let rightBuffer = graph.makeMonoBuffer(right)
      else { return }
      graph.schedule(left: leftBuffer, right: rightBuffer)
    }
    try newTap.start()
    tap = newTap
  }

  /// 取得音のフォーマット（`start()` 後に有効）。0ch のままなら未開始。
  public var captureFormat: AudioStreamBasicDescription {
    tap?.streamFormat ?? AudioStreamBasicDescription()
  }

  public func updateListener(_ orientation: ListenerOrientation) {
    graph.updateListener(orientation)
  }

  public func apply(_ parameters: SpatialAudioParameters) {
    graph.apply(parameters)
  }

  public func stop() {
    tap?.stop()
    tap = nil
    graph.stop()
  }

  // MARK: - 取得ブロックの L/R 抽出

  /// 取得した AudioBufferList を左右のモノ Float 列に分ける。
  /// デインタリーブ（バッファ2本）／インタリーブ（1本2ch）／モノの各配置に対応する。
  static func extractStereo(_ bufferListPointer: UnsafePointer<AudioBufferList>) -> (left: [Float], right: [Float]) {
    let buffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: bufferListPointer)
    )
    if buffers.count >= 2 {
      return (samples(of: buffers[0]), samples(of: buffers[1]))
    }
    guard let only = buffers.first else { return ([], []) }
    let all = samples(of: only)
    let channels = Int(only.mNumberChannels)
    if channels <= 1 { return (all, all) }
    return deinterleave(all, channels: channels)
  }

  /// インタリーブ配置 [L,R,L,R,…] を左右のモノ列に分ける純関数。
  /// モノ（channels<=1）はそのまま両チャンネルに複製する。
  static func deinterleave(_ interleaved: [Float], channels: Int) -> (left: [Float], right: [Float]) {
    guard channels >= 2 else { return (interleaved, interleaved) }
    let frames = interleaved.count / channels
    var left = [Float]()
    var right = [Float]()
    left.reserveCapacity(frames)
    right.reserveCapacity(frames)
    var index = 0
    while index + channels <= interleaved.count {
      left.append(interleaved[index])
      right.append(interleaved[index + 1])
      index += channels
    }
    return (left, right)
  }

  private static func samples(of buffer: AudioBuffer) -> [Float] {
    guard let raw = buffer.mData else { return [] }
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    let pointer = raw.assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
  }
}
