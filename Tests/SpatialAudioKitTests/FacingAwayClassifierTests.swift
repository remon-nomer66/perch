import Foundation
import Testing

@testable import SpatialAudioKit

// 後ろ向き判定の約束: 胴体（首・両肩）が確かに写っていて、頭の正面（鼻・両目）が
// どれも見えないときだけ「後ろ向き」。前を向いているのに顔が取れない場面 — 暗い・
// 手で顔を覆う・頭が画面の外 — を後ろ向きと誤らないことのほうを重く見る
// （誤ると音場が真後ろへ回ってしまう。判定不能なら従来どおり正面へ戻るだけで済む）。

/// 4:3（VGA）。プロバイダの既定の解像度。
private let aspect = 640.0 / 480.0

/// 画面の中央に座った人の、各点の標準の位置（Vision の正規化座標、左下原点）。
/// 信頼度だけを変える表のテストは、位置をこれで固定する。
private let layout: [BodyKeypoints.Joint: (x: Double, y: Double)] = [
  .nose: (0.50, 0.60),
  .leftEye: (0.47, 0.63),
  .rightEye: (0.53, 0.63),
  .leftEar: (0.43, 0.60),
  .rightEar: (0.57, 0.60),
  .neck: (0.50, 0.35),
  .leftShoulder: (0.35, 0.35),
  .rightShoulder: (0.65, 0.35),
  .leftWrist: (0.40, 0.08),
  .rightWrist: (0.60, 0.08),
]

private func makeBody(
  _ confidences: [BodyKeypoints.Joint: Double],
  moving moved: [BodyKeypoints.Joint: (x: Double, y: Double)] = [:]
) -> BodyKeypoints {
  var points: [BodyKeypoints.Joint: BodyKeypoints.Point] = [:]
  for (joint, confidence) in confidences {
    let place = moved[joint] ?? layout[joint]!
    points[joint] = BodyKeypoints.Point(x: place.x, y: place.y, confidence: confidence)
  }
  return BodyKeypoints(points)
}

/// 背中を向けた人: 胴体ははっきり、頭の正面は無し、耳・手首も無し。
private let backView: [BodyKeypoints.Joint: Double] = [
  .neck: 0.9, .leftShoulder: 0.9, .rightShoulder: 0.9,
]

/// 表の1行: 頭の正面（鼻・左目・右目）、耳（左・右）、胴体（首・左肩・右肩）の信頼度。
struct ConfidenceCase: Sendable, CustomTestStringConvertible {
  let name: String
  let front: (nose: Double, leftEye: Double, rightEye: Double)
  let ears: (left: Double, right: Double)
  let torso: (neck: Double, leftShoulder: Double, rightShoulder: Double)
  let expected: HeadPresence

  var testDescription: String { name }

  var keypoints: BodyKeypoints {
    makeBody([
      .nose: front.nose, .leftEye: front.leftEye, .rightEye: front.rightEye,
      .leftEar: ears.left, .rightEar: ears.right,
      .neck: torso.neck, .leftShoulder: torso.leftShoulder, .rightShoulder: torso.rightShoulder,
    ])
  }
}

@Test(
  "信頼度の組み合わせ",
  arguments: [
    ConfidenceCase(
      name: "背中: 胴体は確か、鼻・両目は無い → 後ろ向き",
      front: (0, 0, 0), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .facingAway
    ),
    ConfidenceCase(
      name: "背中で両耳が見える → 後ろ向き（耳は前からも後ろからも見えるので使わない）",
      front: (0, 0, 0), ears: (0.8, 0.8), torso: (0.9, 0.9, 0.9), expected: .facingAway
    ),
    ConfidenceCase(
      name: "鼻が見える → こちら向き（顔検出が落ちただけ）",
      front: (0.8, 0, 0), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .faceVisible
    ),
    ConfidenceCase(
      name: "左目だけ見える → こちら向き",
      front: (0, 0.6, 0), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .faceVisible
    ),
    ConfidenceCase(
      name: "右目だけ見える → こちら向き",
      front: (0, 0, 0.6), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .faceVisible
    ),
    ConfidenceCase(
      name: "暗くて鼻がかすか（閾値ちょうど）→ こちら向き",
      front: (0.2, 0, 0), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .faceVisible
    ),
    ConfidenceCase(
      name: "閾値未満の鼻は見えていない扱い → 後ろ向き",
      front: (0.19, 0.1, 0.1), ears: (0, 0), torso: (0.9, 0.9, 0.9), expected: .facingAway
    ),
    ConfidenceCase(
      name: "胴体が閾値ちょうど → 後ろ向き",
      front: (0, 0, 0), ears: (0, 0), torso: (0.4, 0.4, 0.4), expected: .facingAway
    ),
    ConfidenceCase(
      name: "首が弱い → 判定しない",
      front: (0, 0, 0), ears: (0, 0), torso: (0.3, 0.9, 0.9), expected: .undetermined
    ),
    ConfidenceCase(
      name: "片方の肩が弱い（画面の端で切れた・真横）→ 判定しない",
      front: (0, 0, 0), ears: (0.7, 0), torso: (0.9, 0.9, 0.1), expected: .undetermined
    ),
    ConfidenceCase(
      name: "全体に暗い（胴体も弱い）→ 判定しない",
      front: (0.1, 0.1, 0.1), ears: (0, 0), torso: (0.3, 0.3, 0.3), expected: .undetermined
    ),
    ConfidenceCase(
      name: "何も写っていない → 判定しない",
      front: (0, 0, 0), ears: (0, 0), torso: (0, 0, 0), expected: .undetermined
    ),
  ]
)
func classifiesConfidences(_ row: ConfidenceCase) {
  #expect(FacingAwayClassifier().classify(row.keypoints, imageAspect: aspect) == row.expected)
}

@Test("頭が画面の上端より外に出ている（立ち上がった）なら、正面の点が無くても判定しない")
func headOutOfFrameIsUndetermined() {
  // 首が上端に近いと、鼻・目は「見えない」のでなく「画面の外」かもしれない。
  let cut = makeBody(backView, moving: [.neck: (0.5, 0.85), .leftShoulder: (0.35, 0.85), .rightShoulder: (0.65, 0.85)])
  #expect(FacingAwayClassifier().classify(cut, imageAspect: aspect) == .undetermined)

  // 頭の入る余白があれば判定する。
  let roomy = makeBody(backView, moving: [.neck: (0.5, 0.6), .leftShoulder: (0.35, 0.6), .rightShoulder: (0.65, 0.6)])
  #expect(FacingAwayClassifier().classify(roomy, imageAspect: aspect) == .facingAway)
}

@Test("手首が肩より上にあれば（手で顔を覆っているかもしれない）判定しない")
func raisedHandIsUndetermined() {
  var raised = backView
  raised[.rightWrist] = 0.7
  let covering = makeBody(raised, moving: [.rightWrist: (0.52, 0.6)])
  #expect(FacingAwayClassifier().classify(covering, imageAspect: aspect) == .undetermined)

  // 肩より下の手首（机の上）は関係ない。
  let resting = makeBody(raised)
  #expect(FacingAwayClassifier().classify(resting, imageAspect: aspect) == .facingAway)

  // 位置が肩より上でも、ほとんど見えていない点は根拠にしない。
  raised[.rightWrist] = 0.1
  let faint = makeBody(raised, moving: [.rightWrist: (0.52, 0.6)])
  #expect(FacingAwayClassifier().classify(faint, imageAspect: aspect) == .facingAway)
}

@Test("遠くに小さく写った人（背景の通行人）では判定しない")
func distantPersonIsUndetermined() {
  let far = makeBody(backView, moving: [.leftShoulder: (0.47, 0.35), .rightShoulder: (0.53, 0.35)])
  #expect(FacingAwayClassifier().classify(far, imageAspect: aspect) == .undetermined)
}

@Test("複数人なら、一番大きく写っている人（肩幅が最も広い）で決める")
func theNearestPersonDecides() {
  // 手前の聴き手は後ろ向き、奥の小さな人はこちら向き。
  let listener = makeBody(backView)
  var smallFrontConfidences = backView
  smallFrontConfidences[.nose] = 0.9
  let passerby = makeBody(
    smallFrontConfidences,
    moving: [
      .nose: (0.82, 0.55), .neck: (0.82, 0.45),
      .leftShoulder: (0.78, 0.45), .rightShoulder: (0.86, 0.45),
    ]
  )
  let classifier = FacingAwayClassifier()
  #expect(classifier.classify([passerby, listener], imageAspect: aspect) == .facingAway)

  // 逆に、手前の人がこちらを向いていれば、奥の後ろ姿では後ろ向きにしない。
  var nearFront = backView
  nearFront[.nose] = 0.9
  let nearFacing = makeBody(nearFront)
  let farBack = makeBody(
    backView,
    moving: [.neck: (0.2, 0.45), .leftShoulder: (0.12, 0.45), .rightShoulder: (0.28, 0.45)]
  )
  #expect(classifier.classify([farBack, nearFacing], imageAspect: aspect) == .faceVisible)
}

@Test("手前の人の肩が弱くても、聴き手はその人 — 奥のはっきりした後ろ姿で後ろ向きにしない")
func aFaintNearPersonStillOutranksAClearFarOne() {
  // 手前の聴き手は肩がかすか（暗い・ぶれ）で判定できない。奥の人は後ろ姿がはっきり。
  // 信頼度の足りる人の中で大きさを比べると、奥の人が聴き手に取り違えられる。
  let faintListener = makeBody([.neck: 0.3, .leftShoulder: 0.3, .rightShoulder: 0.3])
  let clearFarBack = makeBody(
    backView,
    moving: [.neck: (0.2, 0.45), .leftShoulder: (0.12, 0.45), .rightShoulder: (0.28, 0.45)]
  )
  let classifier = FacingAwayClassifier()
  #expect(classifier.classify([clearFarBack, faintListener], imageAspect: aspect) == .undetermined)
}

@Test("頭の余白は画像の縦横比を考慮して測る（同じ配置でも横長ほど余白が要る）")
func headroomAccountsForTheAspectRatio() {
  let classifier = FacingAwayClassifier()
  let placed = { (neckY: Double) in
    makeBody(
      backView,
      moving: [.neck: (0.5, neckY), .leftShoulder: (0.35, neckY), .rightShoulder: (0.65, neckY)]
    )
  }
  // 4:3 では幅 0.3 の肩幅は高さの 0.4 にあたり、首の上に 0.28 の余白が要る。
  #expect(classifier.classify(placed(0.70), imageAspect: 4.0 / 3.0) == .facingAway)
  #expect(classifier.classify(placed(0.78), imageAspect: 4.0 / 3.0) == .undetermined)
  // 16:9 では同じ配置でも高さの 0.53 にあたり、首 0.70 では頭が上端からはみ出す。
  #expect(classifier.classify(placed(0.70), imageAspect: 16.0 / 9.0) == .undetermined)
}

@Test("傾いた肩の幅も縦横比を考慮して測る（縦方向の差を幅の単位に直す）")
func tiltedShouldersAccountForTheAspectRatio() {
  let classifier = FacingAwayClassifier()
  // 横 0.06・縦 0.10 の差は、4:3 では幅の 0.096 — 最小の肩幅 0.1 に届かない。
  let narrow = makeBody(backView, moving: [.leftShoulder: (0.47, 0.30), .rightShoulder: (0.53, 0.40)])
  #expect(classifier.classify(narrow, imageAspect: 4.0 / 3.0) == .undetermined)
  // 横 0.08・縦 0.10 なら幅の 0.11 で届く。
  let wide = makeBody(backView, moving: [.leftShoulder: (0.46, 0.30), .rightShoulder: (0.54, 0.40)])
  #expect(classifier.classify(wide, imageAspect: 4.0 / 3.0) == .facingAway)
}

@Test("体が1つも無い・画像の縦横比が不正なら判定しない")
func nothingToJudge() {
  let classifier = FacingAwayClassifier()
  #expect(classifier.classify([], imageAspect: aspect) == .undetermined)
  #expect(classifier.classify(makeBody(backView), imageAspect: 0) == .undetermined)
  #expect(classifier.classify(makeBody(backView), imageAspect: .nan) == .undetermined)
}
