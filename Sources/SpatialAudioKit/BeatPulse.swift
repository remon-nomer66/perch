import Foundation

/// 拍パルスの時間形状。立ち上がりは短いアタック、その後は拍らしく減衰する。
///
/// onset の瞬間に位置を一段で跳ばすと HRTF フィルタが不連続に切り替わって
/// クリック音になる。そこで目標値（拍の強さ、拍ごとに減衰）へ十数msのアタックで
/// 追従させ、跳びを数ブロックに分散させる。パンチは残り、クリックは消える。
public struct BeatPulse: Sendable {
  /// いまのパルスの高さ（0〜1）。位置オフセットや表示に使う。
  public private(set) var level: Double = 0

  private var target: Double = 0
  private let attackTimeConstant: Double
  private let decayTimeConstant: Double

  public init(attackTimeConstant: Double = 0.02, decayTimeConstant: Double = 0.12) {
    self.attackTimeConstant = attackTimeConstant
    self.decayTimeConstant = decayTimeConstant
  }

  /// 1ブロックぶん進める。strength はこのブロックで検出した拍の強さ（無ければ0）。
  public mutating func advance(strength: Double, dt: Double) {
    guard dt > 0 else { return }
    target *= exp(-dt / decayTimeConstant)
    if strength > target { target = strength }
    level += (target - level) * (1 - exp(-dt / attackTimeConstant))
  }
}
