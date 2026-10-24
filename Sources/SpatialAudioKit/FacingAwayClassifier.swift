import Foundation

/// 1人ぶんの体の姿勢の点。Vision に依存しない値型にして、判定を実画像なしで試せる
/// ようにする（Vision からの写しはプロバイダが行う）。
public struct BodyKeypoints: Sendable, Equatable {
  /// 判定に関わる点だけ。耳は判定に使わないが、使わないことを試せるよう持っておく。
  public enum Joint: Sendable, Hashable, CaseIterable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case neck, leftShoulder, rightShoulder
    case leftWrist, rightWrist
  }

  /// Vision の正規化座標（左下原点、x は幅・y は高さに対して 0…1）と信頼度（0…1）。
  public struct Point: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
      self.x = x
      self.y = y
      self.confidence = confidence
    }
  }

  public let points: [Joint: Point]

  public init(_ points: [Joint: Point]) {
    self.points = points
  }

  /// 見つからなかった点は信頼度 0。
  public func confidence(of joint: Joint) -> Double {
    points[joint]?.confidence ?? 0
  }

  /// 信頼度が `minimum` 以上のときだけ、その点を返す。
  func point(_ joint: Joint, atLeast minimum: Double) -> Point? {
    guard let point = points[joint], point.confidence >= minimum else { return nil }
    return point
  }
}

/// 顔検出が顔を見つけられなかったフレームで、写っている人が後ろを向いているかを決める。
///
/// 「人の形はあるが顔が無い」だけでは後ろ向きと決めない。前を向いたまま顔が取れない
/// 場面 — 暗い・手で顔を覆う・立ち上がって頭が画面の外・遠くの別人 — がいくらでもあり、
/// 誤ると音場が真後ろへ回ってしまう。迷ったら `.undetermined`（従来どおり正面へ戻す）に
/// 倒し、次のすべてが揃ったときだけ `.facingAway` とする:
///
/// 1. 頭の正面の点（鼻・両目）がどれも見えない。どれか1つでもかすかに見えれば、
///    こちらを向いている（顔検出が落ちただけ）とみなす。
///    耳は使わない: 耳は正面からも真後ろからも見えるので、向きを何も語らない。
/// 2. 胴体（首・両肩）がはっきり写っている。片方の肩が欠けるのは、画面の端で切れて
///    いるか真横を向いているときで、どちらも後ろ向きの根拠にならない。
/// 3. 遠くの小さな人ではない（背景を横切る別人を聴き手と取り違えない）。
/// 4. 首の上に頭の入る余白がある。首が上端に近ければ、鼻・目は「見えない」のでなく
///    「画面の外」にあるだけかもしれない。
/// 5. 手首が肩より上に無い。手で顔を覆うと、こちら向きでも鼻・目が消える。
///
/// しきい値は実機で詰める前提の初期値で、ここに集めておく。
public struct FacingAwayClassifier: Sendable {
  /// 頭の正面の点を「見えている」とみなす信頼度。低いほど後ろ向きと言いにくくなる
  /// （誤判定を避ける側）。
  public let frontConfidence: Double
  /// 胴体の点を「はっきり写っている」とみなす信頼度。
  public let torsoConfidence: Double
  /// 上げた手首を「顔を覆っているかもしれない」根拠にする信頼度。
  public let handConfidence: Double
  /// 聴き手として扱う最小の肩幅（画像の幅に対する比）。
  public let minShoulderSpan: Double
  /// 首から上に必要な余白（肩幅の何倍か）。首の付け根から目の高さまでがおよそ肩幅の
  /// 0.6 倍なので、少し余裕を見る。
  public let headroom: Double

  public init(
    frontConfidence: Double = 0.2,
    torsoConfidence: Double = 0.4,
    handConfidence: Double = 0.2,
    minShoulderSpan: Double = 0.1,
    headroom: Double = 0.7
  ) {
    self.frontConfidence = frontConfidence
    self.torsoConfidence = torsoConfidence
    self.handConfidence = handConfidence
    self.minShoulderSpan = minShoulderSpan
    self.headroom = headroom
  }

  private static let frontJoints: [BodyKeypoints.Joint] = [.nose, .leftEye, .rightEye]
  private static let wristJoints: [BodyKeypoints.Joint] = [.leftWrist, .rightWrist]
  /// 聴き手を大きさで選ぶときに、肩の位置を使ってよい最低限の信頼度。判定のしきい値
  /// （`torsoConfidence`）よりずっと低い — 位置がおおよそ合っていれば大きさは比べられる。
  private static let sizingConfidence = 0.1

  /// 写っている全員から決める。一番大きく写っている（肩幅の最も広い）人を聴き手と
  /// みなす — カメラの前に座る聴き手は、背景の人より大きく写る。
  ///
  /// 選ぶのは判定より先で、判定のしきい値は使わない。しきい値を満たす人の中で比べると、
  /// 手前の聴き手の肩がかすかなとき（暗い・ぶれ）に、奥のはっきりした後ろ姿が聴き手に
  /// 取り違えられて後ろ向きになる。手前の人が判定できないなら、判定不能のままにする。
  /// - Parameter imageAspect: 画像の 幅 ÷ 高さ。
  public func classify(_ bodies: [BodyKeypoints], imageAspect: Double) -> HeadPresence {
    let primary = bodies.max {
      shoulderSpan(of: $0, imageAspect: imageAspect) < shoulderSpan(of: $1, imageAspect: imageAspect)
    }
    guard let primary else { return .undetermined }
    return classify(primary, imageAspect: imageAspect)
  }

  /// 1人ぶんを判定する。
  /// - Parameter imageAspect: 画像の 幅 ÷ 高さ。正規化座標の x と y の長さを揃えるのに使う。
  public func classify(_ body: BodyKeypoints, imageAspect: Double) -> HeadPresence {
    guard imageAspect.isFinite, imageAspect > 0 else { return .undetermined }

    if Self.frontJoints.contains(where: { body.confidence(of: $0) >= frontConfidence }) {
      return .faceVisible
    }
    guard let neck = body.point(.neck, atLeast: torsoConfidence),
      let left = body.point(.leftShoulder, atLeast: torsoConfidence),
      let right = body.point(.rightShoulder, atLeast: torsoConfidence)
    else { return .undetermined }

    let spanInWidths = Self.distanceInWidths(left, right, imageAspect: imageAspect)
    guard spanInWidths >= minShoulderSpan else { return .undetermined }

    // y は高さに対する比なので、肩幅も高さに対する比へ直してから足す。
    let spanInHeights = spanInWidths * imageAspect
    guard neck.y + headroom * spanInHeights <= 1 else { return .undetermined }

    let shoulderLine = min(left.y, right.y)
    let handRaised = Self.wristJoints.contains { joint in
      guard let wrist = body.point(joint, atLeast: handConfidence) else { return false }
      return wrist.y >= shoulderLine
    }
    guard !handRaised else { return .undetermined }

    return .facingAway
  }

  /// 聴き手を選ぶための肩幅（画像の幅に対する比）。両肩の位置が無ければ 0。
  private func shoulderSpan(of body: BodyKeypoints, imageAspect: Double) -> Double {
    guard imageAspect.isFinite, imageAspect > 0,
      let left = body.point(.leftShoulder, atLeast: Self.sizingConfidence),
      let right = body.point(.rightShoulder, atLeast: Self.sizingConfidence)
    else { return 0 }
    return Self.distanceInWidths(left, right, imageAspect: imageAspect)
  }

  /// 2点間の距離を、画像の幅に対する比で。y は高さに対する比なので幅の単位へ直す。
  private static func distanceInWidths(
    _ a: BodyKeypoints.Point, _ b: BodyKeypoints.Point, imageAspect: Double
  ) -> Double {
    hypot(a.x - b.x, (a.y - b.y) / imageAspect)
  }
}
