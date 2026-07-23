import AVFoundation
import CoreAudio

/// マルチバンド + ミッド/サイドの設定。
public struct MultibandConfig: Sendable, Equatable {
  /// 低域と中高域を分けるクロスオーバー周波数（Hz）。
  public var crossover: Double
  /// 左右のサイド音源を置く開き角（度）。広いほど左右に開く。
  public var sideSpreadDegrees: Double
  /// 音源までの距離（メートル）。大きいほど頭の外へ押し出す。
  public var distance: Double
  /// サイド成分の強調（1で自然、>1で左右を広げる）。
  public var sideWidth: Float
  /// レンダリング品質。
  public var quality: SpatialRenderingQuality

  public init(
    crossover: Double = 250,
    sideSpreadDegrees: Double = 55,
    distance: Double = 1.4,
    sideWidth: Float = 1.4,
    quality: SpatialRenderingQuality = .high
  ) {
    self.crossover = crossover
    self.sideSpreadDegrees = sideSpreadDegrees
    self.distance = distance
    self.sideWidth = sideWidth
    self.quality = quality
  }
}

/// システム音をマルチバンド + M/S で空間化する。
///
/// 各ブロックで L/R をクロスオーバーで低域/中高域に分け、**低域は L+R のモノを中央に
/// 固定**（無指向性なので中央が正解・迫力を保つ）、**中高域は M/S 分解して Mid を中央、
/// Side を左右に広げる**（ミックスの楽器パンを尊重して立体化）。3つの位置付き音源
/// （中央・左・右）へ流す。発音は実機でのみ確認でき、この段階はコンパイル検証まで。
@available(macOS 14.4, *)
public final class MultibandSpatializer: @unchecked Sendable {
  private let graph: PositionedSourceGraph
  private var crossoverLeft: Crossover
  private var crossoverRight: Crossover
  private let config: MultibandConfig
  private let muteOriginal: Bool
  private var tap: SystemAudioTap?

  private enum SourceIndex {
    static let center = 0
    static let left = 1
    static let right = 2
  }

  public init(
    config: MultibandConfig = MultibandConfig(),
    muteOriginal: Bool = true,
    sampleRate: Double = 48_000
  ) throws {
    self.config = config
    self.muteOriginal = muteOriginal
    crossoverLeft = Crossover(cutoff: config.crossover, sampleRate: sampleRate)
    crossoverRight = Crossover(cutoff: config.crossover, sampleRate: sampleRate)

    graph = try PositionedSourceGraph(sampleRate: sampleRate, sourceCount: 3)
    graph.setAlgorithm(config.quality)
    let spread = config.sideSpreadDegrees * .pi / 180
    graph.setPosition(SourceIndex.center, SphericalDirection(azimuth: 0, elevation: 0, distance: config.distance))
    graph.setPosition(SourceIndex.left, SphericalDirection(azimuth: -spread, elevation: 0, distance: config.distance))
    graph.setPosition(SourceIndex.right, SphericalDirection(azimuth: spread, elevation: 0, distance: config.distance))
  }

  public func start() throws {
    try graph.start()
    let newTap = SystemAudioTap(muteOriginal: muteOriginal, excludeCurrentProcess: true) { [self] bufferListPointer in
      self.process(bufferListPointer)
    }
    try newTap.start()
    tap = newTap
  }

  public var captureFormat: AudioStreamBasicDescription {
    tap?.streamFormat ?? AudioStreamBasicDescription()
  }

  public func updateListener(_ orientation: ListenerOrientation) {
    graph.updateListener(orientation)
  }

  public func stop() {
    tap?.stop()
    tap = nil
    graph.stop()
  }

  private func process(_ bufferListPointer: UnsafePointer<AudioBufferList>) {
    let (left, right) = LiveSpatializer.extractStereo(bufferListPointer)
    guard !left.isEmpty, !right.isEmpty else { return }
    let (lowLeft, highLeft) = crossoverLeft.split(left)
    let (lowRight, highRight) = crossoverRight.split(right)
    let mixed = Self.mix(
      lowLeft: lowLeft, lowRight: lowRight,
      highLeft: highLeft, highRight: highRight,
      width: config.sideWidth
    )
    guard !mixed.center.isEmpty,
      let centerBuffer = graph.makeMonoBuffer(mixed.center),
      let leftBuffer = graph.makeMonoBuffer(mixed.left),
      let rightBuffer = graph.makeMonoBuffer(mixed.right)
    else { return }
    graph.schedule(index: SourceIndex.center, buffer: centerBuffer)
    graph.schedule(index: SourceIndex.left, buffer: leftBuffer)
    graph.schedule(index: SourceIndex.right, buffer: rightBuffer)
  }

  /// 帯域分割済みの L/R から、3音源（中央・左・右）の信号を作る純関数。
  ///
  /// - 中央 = 低域モノ(L+R)/2 ＋ 中高域 Mid(L+R)/2
  /// - 左 = 中高域 Side(L−R)/2 × width
  /// - 右 = 左の反転（−Side）
  static func mix(
    lowLeft: [Float], lowRight: [Float],
    highLeft: [Float], highRight: [Float],
    width: Float
  ) -> (center: [Float], left: [Float], right: [Float]) {
    let count = min(lowLeft.count, lowRight.count, highLeft.count, highRight.count)
    var center = [Float](repeating: 0, count: count)
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    for index in 0..<count {
      let lowMono = (lowLeft[index] + lowRight[index]) * 0.5
      let mid = (highLeft[index] + highRight[index]) * 0.5
      let side = (highLeft[index] - highRight[index]) * 0.5 * width
      center[index] = lowMono + mid
      left[index] = side
      right[index] = -side
    }
    return (center, left, right)
  }
}
