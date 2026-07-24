import AVFoundation
import CoreAudio
import Foundation
import os

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

/// 開始時に取得系の前提が崩れていた場合の失敗。
public enum SpatializerStartError: Error, Equatable {
  /// タップの実サンプルレートがグラフの構築レートと一致しない。実レートのまま処理すると
  /// 全システム音の再生速度・ピッチ・BPM がずれるので開始しない。`actual` で作り直せば整合する。
  case sampleRateMismatch(expected: Double, actual: Double)
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

  /// オーディオ・解析・メインの3スレッドが共有するミラー値。Swift ではロック無しの
  /// 共有可変状態はスカラでも未定義動作なので、まとめて一つの unfair lock で守る。
  /// どの臨界区間も数個のスカラのコピーだけで、レンダースレッドが取るのは一瞬。
  private struct SharedState {
    /// True once any capture callback has arrived at all.
    var receivedAudio = false
    /// True once a non-silent sample has been captured. A denied system-audio
    /// permission still fires callbacks, but with silence — so callbacks arriving is
    /// not proof of capture. Real (non-zero) audio is.
    var receivedSignal = false
    // 耳合わせ用の可変ゲイン（メインが書き、オーディオが読む。autoBalance 時は
    // オーディオ側が書き戻す）。
    var lowGain: Float
    var midGain: Float
    var sideWidth: Float
    // ヘッドトラッキングの距離連動（メインが書き、オーディオが読む）。
    var listenerDistanceRatio = 1.0
    // 拍解析の結果ミラー（解析キューが書き、オーディオが読んで消費する）。
    var pendingBeatStrength = 0.0
    var analysisBPM = Double.nan  // NaN = テンポ不明
    // 解析待ちのモノ音声。オーディオ側が積み、解析キューが排出する。in-flight は
    // 常に1つ: 解析が追いつかない時にタスクと配列がキューへ無限に溜まらないため。
    var pendingMono: [Float] = []
    var analysisScheduled = false
    // 表示用スナップショット（オーディオが書き、メインが読む）。
    var display = MovementState(
      centerAzimuth: 0, centerElevation: 0, leftAzimuth: 0, rightAzimuth: 0,
      beatLevel: 0, estimatedBPM: nil, wanderSyncWeight: 0
    )
  }

  private let shared: OSAllocatedUnfairLock<SharedState>

  public var hasReceivedAudio: Bool { shared.withLock { $0.receivedAudio } }
  public var hasAudioSignal: Bool { shared.withLock { $0.receivedSignal } }
  /// 無音走査の打ち切りゲート。オーディオスレッドだけが触る（ロック不要）。
  private var signalSeen = false
  private static let silenceThreshold: Float = 0.0005

  // 音源の基準位置（揺らぎはこれに加算する）と、ゆっくり漂わせる揺らぎ。
  private var centerBase: SphericalDirection
  private var leftBase: SphericalDirection
  private var rightBase: SphericalDirection
  private let wander: PositionWander
  private var elapsedTime: Double = 0
  // 揺らぎのテンポ同期: 推定BPMで拍を刻み、読めている間だけ同期揺らぎへ寄せる。
  private var musicalClock = MusicalClock()

  // 拍リアクティブ: スペクトルフラックスの onset で音場をパルス状に動かす。
  // 解析（FFT・自己相関）は音声コールバックの締切を脅かさないよう専用キューで行い、
  // 結果は `shared` のミラー越しに受け取る。
  private var onsetDetector: SpectralFluxDetector?
  private let analysisQueue = DispatchQueue(label: "SpatialAudioKit.beat-analysis", qos: .userInitiated)
  private var beatPulse = BeatPulse()
  private let beatAmplitude: Double  // ラジアン。0 なら拍リアクティブ無効。

  // 各音源の現在の揺らぎ量（基準位置からのズレ、ラジアン）。オーディオスレッドだけが
  // 触り、ブロック末尾に `shared.display` へスナップショットする。
  private var offCenterAzimuth = 0.0
  private var offCenterElevation = 0.0
  private var offLeftAzimuth = 0.0
  private var offRightAzimuth = 0.0

  // 前回 HRTF に適用した位置。実際に動いた時だけ setPosition を呼び、
  // フィルタの無駄な切り替え（ノイズの種）を起こさないための記録。
  private var appliedAzimuth = [Double](repeating: .nan, count: 3)
  private var appliedElevation = [Double](repeating: .nan, count: 3)
  private static let positionEpsilon = 0.05 * Double.pi / 180

  // 耳合わせ用の可変ゲイン。実体は `shared` にあり、外部にはこれまで通りの
  // プロパティとして見せる。
  public var lowGain: Float {
    get { shared.withLock { $0.lowGain } }
    set { shared.withLock { $0.lowGain = newValue } }
  }
  public var midGain: Float {
    get { shared.withLock { $0.midGain } }
    set { shared.withLock { $0.midGain = newValue } }
  }
  public var sideWidth: Float {
    get { shared.withLock { $0.sideWidth } }
    set { shared.withLock { $0.sideWidth = newValue } }
  }

  // 距離のこもりフィルタ。オーディオスレッドだけが触る。
  private var distanceLowpassLeft = OnePoleLowpass()
  private var distanceLowpassRight = OnePoleLowpass()

  private enum SourceIndex {
    static let center = 0
    static let left = 1
    static let right = 2
  }

  public init(
    config: MultibandConfig = MultibandConfig(),
    muteOriginal: Bool = true,
    autoBalance: Bool = false,
    wanderDegrees: Double = 6,
    beatDegrees: Double = 0,
    sampleRate: Double = 48_000
  ) throws {
    self.muteOriginal = muteOriginal
    self.sampleRate = sampleRate
    shared = OSAllocatedUnfairLock(
      initialState: SharedState(
        lowGain: config.lowGain, midGain: config.midGain, sideWidth: config.sideWidth
      )
    )
    sideSpread = config.sideSpreadDegrees * .pi / 180
    wander = PositionWander(degrees: wanderDegrees)
    beatAmplitude = max(0, beatDegrees) * .pi / 180
    crossoverLeft = Crossover(cutoff: config.crossover, sampleRate: sampleRate)
    crossoverRight = Crossover(cutoff: config.crossover, sampleRate: sampleRate)
    if autoBalance {
      analyzer = BalanceAnalyzer(baselineLowGain: config.lowGain, baselineWidth: config.sideWidth)
    }
    // 拍検出は常時走らせる（拍の表示とテンポ推定のため）。音場を動かすかどうかは
    // beatAmplitude だけで決まる。既定構成（2の冪の FFT サイズ）では失敗しない。
    onsetDetector = SpectralFluxDetector(sampleRate: sampleRate)

    centerBase = SphericalDirection(azimuth: 0, elevation: 0, distance: config.centerDistance)
    leftBase = SphericalDirection(azimuth: -sideSpread, elevation: 0, distance: config.sideDistance)
    rightBase = SphericalDirection(azimuth: sideSpread, elevation: 0, distance: config.sideDistance)

    graph = try PositionedSourceGraph(sampleRate: sampleRate, sourceCount: 3)
    graph.setAlgorithm(config.quality)
    graph.setOutputVolume(config.masterGain)
    graph.setPosition(SourceIndex.center, centerBase)
    graph.setPosition(SourceIndex.left, leftBase)
    graph.setPosition(SourceIndex.right, rightBase)
  }

  public func start() throws {
    try graph.start()
    let newTap = SystemAudioTap(muteOriginal: muteOriginal, excludeCurrentProcess: true) { [self] bufferListPointer in
      self.process(bufferListPointer)
    }
    try newTap.start()
    // タップは出力デバイスのレートでフレームを届ける。グラフの構築レートとずれたまま
    // 進むと全システム音の速度・ピッチ・BPM が狂うので、ここで照合して弾く。
    // 呼び出し側は actual で作り直せばよい。
    let reported = Double(newTap.streamFormat.mSampleRate)
    guard Self.sampleRateMatches(expected: sampleRate, reported: reported) else {
      newTap.stop()
      graph.stop()
      throw SpatializerStartError.sampleRateMismatch(expected: sampleRate, actual: reported)
    }
    tap = newTap
  }

  /// 構築レートとタップの実レートが同じとみなせるか。0 は「読めていない」なので通す
  /// （照合できない以上、開始を妨げない）。
  static func sampleRateMatches(expected: Double, reported: Double) -> Bool {
    reported <= 0 || abs(expected - reported) <= 1
  }

  /// システム音の取得なしで開始する（合成BGMのデモ・検証用）。音は feed で供給する。
  public func startWithoutCapture() throws {
    try graph.start()
  }

  /// 外部のステレオブロックを、取得音と同じ経路（帯域分割→空間化→拍検出）で処理する。
  public func feed(left: [Float], right: [Float]) {
    processStereo(left: left, right: right)
  }

  public var captureFormat: AudioStreamBasicDescription {
    tap?.streamFormat ?? AudioStreamBasicDescription()
  }

  /// 出力構成の変化でエンジンが止まった時の通知（PositionedSourceGraph へ転送）。
  /// `start()` の前に設定すること。
  public var onConfigurationChange: (@Sendable () -> Void)? {
    get { graph.onConfigurationChange }
    set { graph.onConfigurationChange = newValue }
  }

  /// テスト用: グラフのエンジン（構成変更通知の object 一致に使う）。
  var graphEngineForNotifications: AVAudioEngine { graph.engineForNotifications }

  public func updateListener(_ orientation: ListenerOrientation) {
    graph.updateListener(orientation)
  }

  /// ヘッドトラッキングの相対距離（較正時=1.0）。リスナーを幾何のまま後退させ、
  /// 中高域には距離のこもり（一次ローパス）を掛ける。
  public func setListenerDistance(ratio: Double) {
    shared.withLock { $0.listenerDistanceRatio = ratio }
    graph.setListenerZ(DistanceRendering.listenerOffset(ratio: ratio))
  }

  public func setMasterGain(_ gain: Float) { graph.setOutputVolume(gain) }
  public func setCenterDistance(_ distance: Double) {
    centerBase = SphericalDirection(azimuth: 0, elevation: 0, distance: distance)
    graph.setPosition(SourceIndex.center, centerBase)
  }
  public func setSideDistance(_ distance: Double) {
    leftBase = SphericalDirection(azimuth: -sideSpread, elevation: 0, distance: distance)
    rightBase = SphericalDirection(azimuth: sideSpread, elevation: 0, distance: distance)
    graph.setPosition(SourceIndex.left, leftBase)
    graph.setPosition(SourceIndex.right, rightBase)
  }

  /// 各音源を「基準位置 ＋ ゆっくりの揺らぎ ＋ 拍のパルス」へ更新する。
  private func applyMovement(time: Double) {
    reposition(SourceIndex.center, base: centerBase, source: 0, time: time)
    reposition(SourceIndex.left, base: leftBase, source: 1, time: time)
    reposition(SourceIndex.right, base: rightBase, source: 2, time: time)
  }

  private func reposition(_ index: Int, base: SphericalDirection, source: Int, time: Double) {
    // 自由揺らぎ（壁時計）とテンポ同期揺らぎ（拍）を、同期の重みで滑らかに混ぜる。
    let free = wander.offset(source: source, time: time)
    let synced = wander.offset(source: source, beats: musicalClock.beats)
    let weight = musicalClock.syncWeight
    let beat = beatOffset(source: source)
    let azimuthOffset = free.azimuth * (1 - weight) + synced.azimuth * weight + beat.azimuth
    let elevationOffset =
      free.elevation * (1 - weight) + synced.elevation * weight + beat.elevation
    let azimuth = base.azimuth + azimuthOffset
    let elevation = base.elevation + elevationOffset
    // 実際に動いた時だけ HRTF へ適用する。
    if appliedAzimuth[source].isNaN
      || abs(azimuth - appliedAzimuth[source]) > Self.positionEpsilon
      || abs(elevation - appliedElevation[source]) > Self.positionEpsilon {
      appliedAzimuth[source] = azimuth
      appliedElevation[source] = elevation
      graph.setPosition(
        index,
        SphericalDirection(azimuth: azimuth, elevation: elevation, distance: base.distance)
      )
    }
    switch source {
    case SourceIndex.center:
      offCenterAzimuth = azimuthOffset
      offCenterElevation = elevationOffset
    case SourceIndex.left:
      offLeftAzimuth = azimuthOffset
    case SourceIndex.right:
      offRightAzimuth = azimuthOffset
    default:
      break
    }
  }

  /// 表示用の、現在の揺らぎ状態（基準位置からのズレ、度）と拍・テンポ。
  public struct MovementState: Sendable {
    public let centerAzimuth: Double
    public let centerElevation: Double
    public let leftAzimuth: Double
    public let rightAzimuth: Double
    public let beatLevel: Double
    public let estimatedBPM: Double?
    /// 揺らぎがテンポに同期している度合い（0〜1）。
    public let wanderSyncWeight: Double
  }

  public var movementState: MovementState {
    shared.withLock { $0.display }
  }

  /// 拍のパルスによる位置オフセット。拍で左右が外へ開き、中央は軽く上へ跳ねる。
  private func beatOffset(source: Int) -> (azimuth: Double, elevation: Double) {
    guard beatAmplitude > 0, beatPulse.level > 0 else { return (0, 0) }
    let push = beatAmplitude * beatPulse.level
    switch source {
    case SourceIndex.left: return (-push, 0)
    case SourceIndex.right: return (push, 0)
    default: return (0, push * 0.4)
    }
  }

  public func stop() {
    tap?.stop()
    tap = nil
    graph.stop()
    // 解析待ちを捨てる（排出中のタスクは空を見て自分でフラグを下ろす）。
    shared.withLock { $0.pendingMono = [] }
  }

  private func process(_ bufferListPointer: UnsafePointer<AudioBufferList>) {
    let (left, right) = LiveSpatializer.extractStereo(bufferListPointer)
    processStereo(left: left, right: right)
  }

  /// 解析キュー上で、溜まったモノ音声を空になるまで処理する。空を見た時に in-flight
  /// フラグを下ろす（下ろすのと同時に新しい積み込みが次のタスクを起こせる）。
  private func drainAnalysis() {
    guard let onsetDetector else { return }
    while true {
      let mono = shared.withLock { state -> [Float] in
        let pending = state.pendingMono
        state.pendingMono = []
        if pending.isEmpty { state.analysisScheduled = false }
        return pending
      }
      if mono.isEmpty { return }
      let strength = onsetDetector.observe(mono: mono)
      let bpm = onsetDetector.estimatedBPM ?? .nan
      shared.withLock { state in
        if strength > state.pendingBeatStrength { state.pendingBeatStrength = strength }
        state.analysisBPM = bpm
      }
    }
  }

  private func processStereo(left: [Float], right: [Float]) {
    // 共有ミラーはブロックあたり数回、ひとまとめに読む（レンダースレッドが
    // ロックを握るのはスカラのコピーの間だけ）。
    var (lowGain, midGain, sideWidth, distanceRatio) = shared.withLock {
      state -> (Float, Float, Float, Double) in
      state.receivedAudio = true
      return (state.lowGain, state.midGain, state.sideWidth, state.listenerDistanceRatio)
    }
    guard !left.isEmpty, !right.isEmpty else { return }

    // Prove real capture, not just that the callback fired: a denied permission delivers
    // silent buffers. Both channels count — hard-panned material may carry signal in
    // only one. Stop scanning once any signal has been seen.
    if !signalSeen {
      scan: for channel in [left, right] {
        for sample in channel where abs(sample) > Self.silenceThreshold {
          signalSeen = true
          shared.withLock { $0.receivedSignal = true }
          break scan
        }
      }
    }
    let (lowLeft, splitHighLeft) = crossoverLeft.split(left)
    let (lowRight, splitHighRight) = crossoverRight.split(right)

    // 距離のこもり: 遠ざかっているときだけ中高域を暗くする。低音（両耳直通）は
    // 距離でほとんど鈍らないので触らない。
    let distanceCutoff = DistanceRendering.lowpassCutoff(ratio: distanceRatio)
    let highLeft = distanceLowpassLeft.process(
      splitHighLeft, cutoff: distanceCutoff, sampleRate: sampleRate
    )
    let highRight = distanceLowpassRight.process(
      splitHighRight, cutoff: distanceCutoff, sampleRate: sampleRate
    )

    let count = min(lowLeft.count, lowRight.count, highLeft.count, highRight.count)
    if count > 0 {
      let dt = Double(count) / sampleRate
      elapsedTime += dt
      // 自動バランス: 各帯域のレベルを測り、低音ゲインと幅をゆっくり追従させる。
      if analyzer != nil {
        analyzer!.observe(
          lowRMS: Self.rmsOfMean(lowLeft, lowRight, count: count),
          midRMS: Self.rmsOfMean(highLeft, highRight, count: count),
          sideRMS: Self.rmsOfDifference(highLeft, highRight, count: count),
          dt: dt
        )
        let balancedLow = analyzer!.lowGain
        let balancedWidth = analyzer!.sideWidth
        lowGain = balancedLow
        sideWidth = balancedWidth
        shared.withLock {
          $0.lowGain = balancedLow
          $0.sideWidth = balancedWidth
        }
      }

      // 拍・テンポの解析は専用キューへ。ここ（音声スレッド）では積むだけ。in-flight は
      // 常に1タスク: 解析が追いつかない時も、キューに配列と self が無限に溜まらない。
      if onsetDetector != nil {
        var monoBlock = [Float](repeating: 0, count: count)
        for index in 0..<count {
          monoBlock[index] = (left[index] + right[index]) * 0.5
        }
        let mono = monoBlock
        let shouldSchedule = shared.withLock { state -> Bool in
          state.pendingMono.append(contentsOf: mono)
          // 溜まりの上限（約8秒）。超えたら古い方を捨てる — テンポ推定は連続性を
          // 失うが数秒で立ち直る。無限に遅延と記憶を積むよりよい。
          let cap = Int(sampleRate * 8)
          if state.pendingMono.count > cap {
            state.pendingMono.removeFirst(state.pendingMono.count - cap)
          }
          if state.analysisScheduled { return false }
          state.analysisScheduled = true
          return true
        }
        if shouldSchedule {
          analysisQueue.async { [self] in drainAnalysis() }
        }
      }

      // 拍パルス: 解析結果を取り込み、短いアタックで滑らかに立ち上げて減衰させる。
      let (strength, bpm) = shared.withLock { state -> (Double, Double) in
        let pending = state.pendingBeatStrength
        state.pendingBeatStrength = 0
        return (pending, state.analysisBPM)
      }
      beatPulse.advance(strength: strength, dt: dt)
      musicalClock.advance(dt: dt, bpm: bpm.isNaN ? nil : bpm)

      // ゆっくりの揺らぎ ＋ 拍のパルスで音源を動かす（動く設定の時だけ）。
      if wander.amplitude > 0 || beatAmplitude > 0 {
        applyMovement(time: elapsedTime)
      }

      // 表示用スナップショット（メインスレッドは movementState でこれを読む）。
      let toDegrees = 180.0 / Double.pi
      let display = MovementState(
        centerAzimuth: offCenterAzimuth * toDegrees,
        centerElevation: offCenterElevation * toDegrees,
        leftAzimuth: offLeftAzimuth * toDegrees,
        rightAzimuth: offRightAzimuth * toDegrees,
        beatLevel: beatPulse.level,
        estimatedBPM: bpm.isNaN ? nil : bpm,
        wanderSyncWeight: musicalClock.syncWeight
      )
      shared.withLock { $0.display = display }
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
