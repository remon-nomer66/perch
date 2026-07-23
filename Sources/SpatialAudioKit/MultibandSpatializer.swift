import AVFoundation
import CoreAudio

/// マルチバンド + ミッド/サイドの設定。
public struct MultibandConfig: Sendable, Equatable {
  /// 低域と中高域を分けるクロスオーバー周波数（Hz）。
  public var crossover: Double
  /// 低域のゲイン。両耳へ直通で出す低音の力強さ。
  public var lowGain: Float
  /// 中央（ボーカル等 Mid）のゲイン。上げると歌詞が前に出る。
  public var midGain: Float
  /// サイド成分の強調（1で自然、>1で左右を広げる）。
  public var sideWidth: Float
  /// 左右のサイド音源を置く開き角（度）。
  public var sideSpreadDegrees: Double
  /// 中央音源の距離（メートル）。近いほど前に出る。
  public var centerDistance: Double
  /// 左右音源の距離（メートル）。遠いほど広く・後ろへ。
  public var sideDistance: Double
  /// 全体の出力音量（メイクアップ）。
  public var masterGain: Float
  /// レンダリング品質。
  public var quality: SpatialRenderingQuality

  public init(
    crossover: Double = 250,
    lowGain: Float = 1.3,
    midGain: Float = 1.15,
    sideWidth: Float = 1.1,
    sideSpreadDegrees: Double = 55,
    centerDistance: Double = 1.0,
    sideDistance: Double = 1.6,
    masterGain: Float = 1.1,
    quality: SpatialRenderingQuality = .high
  ) {
    self.crossover = crossover
    self.lowGain = lowGain
    self.midGain = midGain
    self.sideWidth = sideWidth
    self.sideSpreadDegrees = sideSpreadDegrees
    self.centerDistance = centerDistance
    self.sideDistance = sideDistance
    self.masterGain = masterGain
    self.quality = quality
  }
}

/// システム音をマルチバンド + M/S で空間化する。
///
/// **低域は HRTF を通さず、両耳へフルレベルで直通**する（無指向性の低音は空間化すると
/// 痩せるので、両耳にガツンと届ける方が力強い）。**中高域だけを M/S で空間化**：
/// Mid（ボーカル等）を中央に、Side（パンされた楽器）を左右に広げる。
/// ゲイン・幅・距離は実機で耳合わせできるよう可変。発音は実機でのみ確認できる。
@available(macOS 14.4, *)
public final class MultibandSpatializer: @unchecked Sendable {
  private let graph: PositionedSourceGraph
  private var crossoverLeft: Crossover
  private var crossoverRight: Crossover
  private let sideSpread: Double
  private let sampleRate: Double
  private var analyzer: BalanceAnalyzer?
  private var tap: SystemAudioTap?
  private let muteOriginal: Bool

  // オーディオスレッドから読む可変ゲイン（耳合わせ用。単純なFloatなので競合は軽微）。
  public var lowGain: Float
  public var midGain: Float
  public var sideWidth: Float

  private enum SourceIndex {
    static let center = 0
    static let left = 1
    static let right = 2
  }

  public init(
    config: MultibandConfig = MultibandConfig(),
    muteOriginal: Bool = true,
    autoBalance: Bool = false,
    sampleRate: Double = 48_000
  ) throws {
    self.muteOriginal = muteOriginal
    self.sampleRate = sampleRate
    lowGain = config.lowGain
    midGain = config.midGain
    sideWidth = config.sideWidth
    sideSpread = config.sideSpreadDegrees * .pi / 180
    crossoverLeft = Crossover(cutoff: config.crossover, sampleRate: sampleRate)
    crossoverRight = Crossover(cutoff: config.crossover, sampleRate: sampleRate)
    if autoBalance {
      analyzer = BalanceAnalyzer(baselineLowGain: config.lowGain, baselineWidth: config.sideWidth)
    }

    graph = try PositionedSourceGraph(sampleRate: sampleRate, sourceCount: 3)
    graph.setAlgorithm(config.quality)
    graph.setOutputVolume(config.masterGain)
    graph.setPosition(SourceIndex.center, SphericalDirection(azimuth: 0, elevation: 0, distance: config.centerDistance))
    graph.setPosition(SourceIndex.left, SphericalDirection(azimuth: -sideSpread, elevation: 0, distance: config.sideDistance))
    graph.setPosition(SourceIndex.right, SphericalDirection(azimuth: sideSpread, elevation: 0, distance: config.sideDistance))
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

  public func setMasterGain(_ gain: Float) { graph.setOutputVolume(gain) }
  public func setCenterDistance(_ distance: Double) {
    graph.setPosition(SourceIndex.center, SphericalDirection(azimuth: 0, elevation: 0, distance: distance))
  }
  public func setSideDistance(_ distance: Double) {
    graph.setPosition(SourceIndex.left, SphericalDirection(azimuth: -sideSpread, elevation: 0, distance: distance))
    graph.setPosition(SourceIndex.right, SphericalDirection(azimuth: sideSpread, elevation: 0, distance: distance))
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

    // 自動バランス: 各帯域のレベルを測り、低音ゲインと幅をゆっくり追従させる。
    if analyzer != nil {
      let count = min(lowLeft.count, lowRight.count, highLeft.count, highRight.count)
      if count > 0 {
        analyzer!.observe(
          lowRMS: Self.rmsOfMean(lowLeft, lowRight, count: count),
          midRMS: Self.rmsOfMean(highLeft, highRight, count: count),
          sideRMS: Self.rmsOfDifference(highLeft, highRight, count: count),
          dt: Double(count) / sampleRate
        )
        lowGain = analyzer!.lowGain
        sideWidth = analyzer!.sideWidth
      }
    }

    let mixed = Self.mix(
      lowLeft: lowLeft, lowRight: lowRight,
      highLeft: highLeft, highRight: highRight,
      lowGain: lowGain, midGain: midGain, width: sideWidth
    )
    // 低音は HRTF を通さず両耳へ直通。
    if let bass = graph.makeStereoBuffer(left: mixed.bassLeft, right: mixed.bassRight) {
      graph.scheduleDirect(buffer: bass)
    }
    // 中高域だけ HRTF 空間化。
    if let center = graph.makeMonoBuffer(mixed.center) {
      graph.schedule(index: SourceIndex.center, buffer: center)
    }
    if let sideLeft = graph.makeMonoBuffer(mixed.sideLeft),
      let sideRight = graph.makeMonoBuffer(mixed.sideRight) {
      graph.schedule(index: SourceIndex.left, buffer: sideLeft)
      graph.schedule(index: SourceIndex.right, buffer: sideRight)
    }
  }

  /// 帯域分割済みの L/R から各出力を作る純関数。
  ///
  /// - 低音（両耳直通）: L/R をそのまま × lowGain（無指向性なので両耳にフルで出す）
  /// - 中央(HRTF): 中高域 Mid=(L+R)/2 × midGain（ボーカル等）
  /// - 左/右(HRTF): 中高域 Side=(L−R)/2 × width と、その反転
  static func mix(
    lowLeft: [Float], lowRight: [Float],
    highLeft: [Float], highRight: [Float],
    lowGain: Float, midGain: Float, width: Float
  ) -> (bassLeft: [Float], bassRight: [Float], center: [Float], sideLeft: [Float], sideRight: [Float]) {
    let count = min(lowLeft.count, lowRight.count, highLeft.count, highRight.count)
    var bassLeft = [Float](repeating: 0, count: count)
    var bassRight = [Float](repeating: 0, count: count)
    var center = [Float](repeating: 0, count: count)
    var sideLeft = [Float](repeating: 0, count: count)
    var sideRight = [Float](repeating: 0, count: count)
    for index in 0..<count {
      bassLeft[index] = lowLeft[index] * lowGain
      bassRight[index] = lowRight[index] * lowGain
      let mid = (highLeft[index] + highRight[index]) * 0.5
      let side = (highLeft[index] - highRight[index]) * 0.5 * width
      center[index] = mid * midGain
      sideLeft[index] = side
      sideRight[index] = -side
    }
    return (bassLeft, bassRight, center, sideLeft, sideRight)
  }

  /// (a+b)/2 の RMS（中央成分のレベル）。
  static func rmsOfMean(_ a: [Float], _ b: [Float], count: Int) -> Double {
    guard count > 0 else { return 0 }
    var sum = 0.0
    for index in 0..<count {
      let value = (Double(a[index]) + Double(b[index])) * 0.5
      sum += value * value
    }
    return (sum / Double(count)).squareRoot()
  }

  /// (a−b)/2 の RMS（左右差＝サイド成分のレベル）。
  static func rmsOfDifference(_ a: [Float], _ b: [Float], count: Int) -> Double {
    guard count > 0 else { return 0 }
    var sum = 0.0
    for index in 0..<count {
      let value = (Double(a[index]) - Double(b[index])) * 0.5
      sum += value * value
    }
    return (sum / Double(count)).squareRoot()
  }
}
