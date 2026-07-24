import Foundation

/// 推定テンポに合わせて「拍」を刻む時計。揺らぎを曲のリズムに同期させる位相源。
///
/// BPM が読めている間は拍を積分して進め、同期の重み（syncWeight）を 1 へ寄せる。
/// 読めなくなっても拍は最後の BPM で刻み続け（止めると位相が跳ぶ）、重みだけを
/// 0 へ滑らかに戻す。呼び出し側は「自由揺らぎ×(1−w) + 同期揺らぎ×w」で混ぜれば、
/// 同期の入り・抜けがシームレスになる。
public struct MusicalClock: Sendable {
  /// 積算した拍数。テンポ同期揺らぎの位相に使う。
  public private(set) var beats: Double = 0
  /// 同期の重み（0〜1）。テンポが読めている時間が続くほど 1 に近づく。
  public private(set) var syncWeight: Double = 0

  private var lastBPM: Double?
  private let weightTimeConstant: Double

  public init(weightTimeConstant: Double = 2.0) {
    self.weightTimeConstant = weightTimeConstant
  }

  /// 1ブロックぶん時を進める。bpm はそのときの推定テンポ（不明なら nil）。
  public mutating func advance(dt: Double, bpm: Double?) {
    guard dt > 0 else { return }
    if let bpm, bpm > 0 { lastBPM = bpm }
    if let lastBPM { beats += dt * lastBPM / 60 }
    let target: Double = bpm != nil ? 1 : 0
    let alpha = ExponentialAverage.alpha(dt: dt, timeConstant: weightTimeConstant)
    syncWeight += alpha * (target - syncWeight)
  }
}
