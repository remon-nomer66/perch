import Foundation

/// 「正面」の較正。追従を有効にした直後の姿勢を集めて平均し、以後はその平均からの
/// 差分（`center⁻¹ × 姿勢`）を音声側へ流す。再センターは作り直すだけ。
///
/// カメラ由来の姿勢は毎フレーム絶対値でドリフトしないため、較正は一度で済む。
/// 平均はクォータニオンの逐次 slerp（1/n 重み）で取り、Euler 成分平均の不連続を避ける。
public struct PoseCenter: Sendable {
  public enum Phase: Equatable, Sendable {
    case calibrating(progress: Double)
    case ready
  }

  private let sampleTarget: Int
  private var count = 0
  private var mean = Rotation.identity
  private var ipds: [Double] = []

  public private(set) var phase: Phase = .calibrating(progress: 0)

  /// - Parameter sampleTarget: 較正に使うサンプル数。15fps なら 15 で約1秒。
  public init(sampleTarget: Int = 15) {
    self.sampleTarget = max(1, sampleTarget)
  }

  @discardableResult
  public mutating func add(rotation: Rotation, pixelIPD: Double?) -> Phase {
    guard case .calibrating = phase else { return phase }
    count += 1
    mean = count == 1 ? rotation : mean.slerp(to: rotation, fraction: 1 / Double(count))
    if let pixelIPD, pixelIPD > 0 {
      ipds.append(pixelIPD)
    }
    phase = count >= sampleTarget
      ? .ready
      : .calibrating(progress: Double(count) / Double(sampleTarget))
    return phase
  }

  /// 較正済みの「正面」。較正が終わるまでは nil。
  public var center: Rotation? {
    phase == .ready ? mean : nil
  }

  /// 較正中に観測したピクセル瞳孔間距離の中央値（相対距離の基準）。
  /// 瞳が一度も取れていなければ nil — その場合、距離連動は始められない。
  public var referenceIPD: Double? {
    guard phase == .ready, !ipds.isEmpty else { return nil }
    let sorted = ipds.sorted()
    return sorted[sorted.count / 2]
  }

  /// 正面からの差分。較正が済んでいなければそのまま返す（呼び出し側は phase で待つ）。
  public func centered(_ rotation: Rotation) -> Rotation {
    guard phase == .ready else { return rotation }
    return mean.inverse * rotation
  }
}
