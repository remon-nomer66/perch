import Foundation

/// フラックス包絡の自己相関から、いま流れている曲のテンポ（BPM）を推定する。
///
/// librosa のテンポグラムと同系の考え方のストリーミング版。直近 windowSeconds の
/// フラックス包絡（拍で山になる）を貯め、自己相関のピークを支配的な周期として読む。
/// 候補は「正規化相関 × 120BPM中心の対数ガウス事前分布」で採点し、8分/2拍との
/// オクターブ取り違えを音楽的な範囲へ寄せる。周期性が弱い（無音・環境音など）
/// あいだは bpm を nil にする。
public struct TempoEstimator: Sendable {
  /// 推定テンポ。周期性が確認できないときは nil。
  public private(set) var bpm: Double?

  private var envelope: [Double] = []
  private var capacity = 0
  private var updateStride = 0
  private var sinceLastUpdate = 0
  private var history: [Double] = []
  private var misses = 0

  private let windowSeconds: Double
  private let minBPM: Double
  private let maxBPM: Double
  private let confidenceThreshold: Double

  public init(
    windowSeconds: Double = 8,
    minBPM: Double = 60,
    maxBPM: Double = 200,
    confidenceThreshold: Double = 0.15
  ) {
    self.windowSeconds = windowSeconds
    self.minBPM = max(minBPM, 1)
    self.maxBPM = max(maxBPM, self.minBPM + 1)
    self.confidenceThreshold = confidenceThreshold
  }

  /// 1ホップ分のフラックスを観測する。dt はホップ間隔（一定であること）。
  public mutating func observe(flux: Double, dt: Double) {
    guard dt > 0 else { return }
    if capacity == 0 {
      capacity = max(Int(windowSeconds / dt), 16)
      updateStride = max(Int(0.5 / dt), 1)  // 推定は0.5秒ごとで十分
      envelope.reserveCapacity(capacity + 1)
    }
    envelope.append(flux)
    if envelope.count > capacity {
      envelope.removeFirst(envelope.count - capacity)
    }
    sinceLastUpdate += 1
    guard sinceLastUpdate >= updateStride else { return }
    sinceLastUpdate = 0
    update(dt: dt)
  }

  private mutating func update(dt: Double) {
    let maxLag = Int((60 / minBPM) / dt)
    let minLag = max(Int((60 / maxBPM) / dt), 1)
    // 最長ラグの2倍たまるまでは判定しない（相関の根拠が薄いため）。
    guard minLag < maxLag, envelope.count >= maxLag * 2 else { return }

    // 音が止まったら素早く消す: 窓の奥に昔の拍が残っていても、直近2秒が
    // ほぼ無音ならもう「いま流れている曲」のテンポではない。
    let recentCount = min(envelope.count, max(Int(2.0 / dt), 1))
    guard (envelope.suffix(recentCount).max() ?? 0) > 1e-4 else { return registerMiss() }

    guard
      let found = Self.dominantPeriod(
        envelope: envelope, dt: dt, minLag: minLag, maxLag: maxLag, priorCenterBPM: 120),
      found.confidence >= confidenceThreshold
    else { return registerMiss() }
    misses = 0
    history.append(60 / found.period)
    if history.count > 3 { history.removeFirst(history.count - 3) }
    // 直近3回の中央値で、一瞬の読み違いに引きずられないようにする。
    bpm = history.sorted()[history.count / 2]
  }

  /// 読み取れなかった回を数え、続くようなら表示を消す（一瞬の空白では消さない）。
  private mutating func registerMiss() {
    misses += 1
    if misses >= 3 {
      bpm = nil
      history.removeAll()
    }
  }

  /// 平均除去した包絡の自己相関から支配的な周期を探す純関数。
  /// confidence はラグ0のエネルギーで正規化した相関（0〜1目安）。
  static func dominantPeriod(
    envelope: [Double], dt: Double, minLag: Int, maxLag: Int, priorCenterBPM: Double
  ) -> (period: Double, confidence: Double)? {
    let count = envelope.count
    guard count > maxLag + 1, minLag >= 1 else { return nil }
    let mean = envelope.reduce(0, +) / Double(count)
    let centered = envelope.map { $0 - mean }
    var energy = 0.0
    for value in centered { energy += value * value }
    guard energy > 1e-12 else { return nil }

    var correlations = [Double](repeating: 0, count: maxLag + 2)
    for lag in max(minLag - 1, 1)...(maxLag + 1) where lag < count {
      var sum = 0.0
      for index in lag..<count { sum += centered[index] * centered[index - lag] }
      correlations[lag] = sum / energy
    }

    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in minLag...maxLag {
      let lagBPM = 60 / (Double(lag) * dt)
      let octaves = log2(lagBPM / priorCenterBPM)
      let score = correlations[lag] * exp(-0.5 * octaves * octaves)
      if score > bestScore {
        bestScore = score
        bestLag = lag
      }
    }
    guard bestLag >= 1, correlations[bestLag] > 0 else { return nil }

    // 放物線補間でラグをサブサンプル精度へ。
    var refined = Double(bestLag)
    if bestLag >= 2, bestLag + 1 < correlations.count {
      let left = correlations[bestLag - 1]
      let centre = correlations[bestLag]
      let right = correlations[bestLag + 1]
      let denominator = left - 2 * centre + right
      if abs(denominator) > 1e-12 {
        let delta = 0.5 * (left - right) / denominator
        if abs(delta) < 1 { refined += delta }
      }
    }
    return (period: refined * dt, confidence: correlations[bestLag])
  }
}
