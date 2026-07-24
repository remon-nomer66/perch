import Foundation

/// 姿勢ソース1回ぶんの観測。生フレームは含めない — プロバイダの外に出るのは
/// この Sendable な値だけで、画像はプロバイダのキューを出ない。
public struct HeadPoseSample: Sendable, Equatable {
  /// 観測時刻（秒、単調増加。フレームのプレゼンテーション時刻）。
  public let time: Double
  /// 頭の回転。nil はロスト（顔が見つからない／姿勢角が取れない）。
  public let rotation: Rotation?
  /// ピクセル瞳孔間距離。瞳が取れないフレームは nil。
  public let pixelIPD: Double?
  /// 顔バウンディングボックスの幅（ピクセル）。距離のフォールバック用。
  public let faceWidth: Double?

  public init(time: Double, rotation: Rotation?, pixelIPD: Double?, faceWidth: Double?) {
    self.time = time
    self.rotation = rotation
    self.pixelIPD = pixelIPD
    self.faceWidth = faceWidth
  }
}

/// 頭部姿勢の供給源。カメラ（Vision）が主経路で、対応ヘッドホンの IMU
/// （CMHeadphoneMotionManager）を将来ここに差す（計画のスパイクで評価してから）。
public protocol HeadPoseProvider: AnyObject, Sendable {
  /// 観測の流れ。最新値だけ持てばよい（詰まったら古いものから捨てる）。
  /// **終端は「ソースが止まった」の合図**（明示 stop か、カメラの異常終了）。
  var samples: AsyncStream<HeadPoseSample> { get }
  /// 実際に観測が走り出す（か失敗が確定する）まで返らない。
  func start() async throws
  func stop()
}
