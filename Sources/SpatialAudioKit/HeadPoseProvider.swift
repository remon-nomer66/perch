import Foundation

/// 1フレームに聴き手がどう写っていたか。回転が取れないフレームを「誰もいない」と
/// 「後ろを向いている」に分けるための情報で、音場をどちらへ倒すかがこれで変わる
/// （前者は正面へ戻し、後者は背後へ回す）。
public enum HeadPresence: Sendable, Equatable {
  /// 頭の正面が見えている。顔検出が顔を見つけたか、体の姿勢で鼻・目が見えた。
  /// 姿勢角が取れていれば `HeadPoseSample.rotation` に入る。
  case faceVisible
  /// 顔は見えないが、カメラに背を向けた人が写っている。
  case facingAway
  /// 顔も、背を向けた人も見つからない（誰もいない・暗い・判定できない）。
  case undetermined
}

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
  /// 聴き手の写り方。回転が nil のときに、正面へ戻すか背後へ回すかを分ける。
  public let presence: HeadPresence

  /// 写り方を回転の有無から決める従来の作り方: 回転があれば顔あり、無ければ判定不能。
  /// 後ろ向きを判定しないソース（将来の IMU など）はこれで足りる。
  public init(time: Double, rotation: Rotation?, pixelIPD: Double?, faceWidth: Double?) {
    self.init(
      time: time, rotation: rotation, pixelIPD: pixelIPD, faceWidth: faceWidth,
      presence: rotation == nil ? .undetermined : .faceVisible
    )
  }

  /// 写り方を明示する作り方。回転が取れていれば顔は見えているので、`presence` に
  /// 関わらず `.faceVisible` に揃える — 「回転ありの後ろ向き」という矛盾した観測を作らせない。
  public init(
    time: Double, rotation: Rotation?, pixelIPD: Double?, faceWidth: Double?,
    presence: HeadPresence
  ) {
    self.time = time
    self.rotation = rotation
    self.pixelIPD = pixelIPD
    self.faceWidth = faceWidth
    self.presence = rotation == nil ? presence : .faceVisible
  }

  /// 顔は見えないが、背を向けた人が写っていたフレーム。姿勢も距離も測れない。
  public static func facingAway(time: Double) -> HeadPoseSample {
    HeadPoseSample(time: time, rotation: nil, pixelIPD: nil, faceWidth: nil, presence: .facingAway)
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
