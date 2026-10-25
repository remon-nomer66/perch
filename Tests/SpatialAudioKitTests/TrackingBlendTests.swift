import Foundation
import Testing

@testable import SpatialAudioKit

// ロスト受け皿の約束: 切れたらゆっくり中立へ、戻ったらゆっくり追従へ。
// 距離も同じ重みで 1.0（中立）へ — 見失いを「離席」と誤解して音量を下げない。

@Test("追跡が続けば出力は追跡値に達する")
func trackingReachesTheTarget() {
  var blend = TrackingBlend(fadeIn: 0.4, fadeOut: 2.0)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  var output = Rotation.identity
  for _ in 0..<30 {
    (output, _) = blend.advance(tracked: target, distanceRatio: 1.8, dt: 1.0 / 15)
  }
  #expect(output.angle(to: target) < 1e-6)
}

@Test("ロストで fadeOut 経過後は中立（正面・距離1）へ戻る")
func lostFadesToNeutral() {
  var blend = TrackingBlend(fadeIn: 0.1, fadeOut: 1.0)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  for _ in 0..<15 {
    _ = blend.advance(tracked: target, distanceRatio: 2.0, dt: 1.0 / 15)
  }
  var output = (rotation: Rotation.identity, distanceRatio: 0.0)
  for _ in 0..<20 {
    output = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  #expect(output.rotation.angle(to: .identity) < 1e-6)
  #expect(abs(output.distanceRatio - 1.0) < 1e-6)
  #expect(blend.isNeutral)
}

@Test("ロスト直後は一気に飛ばず、途中の値を通る")
func lostFadesGradually() {
  var blend = TrackingBlend(fadeIn: 0.1, fadeOut: 2.0)
  let target = Rotation(yaw: 0.6, pitch: 0, roll: 0)
  for _ in 0..<15 {
    _ = blend.advance(tracked: target, distanceRatio: nil, dt: 1.0 / 15)
  }
  // ロスト 0.5 秒後: まだ半分以上残っているはず（fadeOut 2 秒）。
  var output = Rotation.identity
  for _ in 0..<8 {
    (output, _) = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  let yaw = output.eulerAngles.yaw
  #expect(yaw > 0.3 && yaw < 0.6, "段階的に戻ること (実測 \(yaw))")
}

@Test("復帰したら fadeIn でゆっくり追従に戻る")
func reacquireRampsBackIn() {
  var blend = TrackingBlend(fadeIn: 1.0, fadeOut: 0.1)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  // 一度完全に中立へ。
  for _ in 0..<30 {
    _ = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  // 復帰 1 フレーム目: まだ目標には遠い。
  let (first, _) = blend.advance(tracked: target, distanceRatio: nil, dt: 1.0 / 15)
  #expect(first.angle(to: target) > 0.3)
}

// MARK: - 後ろ向き

// 後ろ向きの約束: 較正した正面に対して真後ろ（yaw 180°、pitch・roll 0）へ、最後に
// 追跡していた yaw の側から滑らかに回す。顔が戻れば即座に戻り始め、戻ってきた顔の
// 側を通る。途中で道を乗り換えない（音場が反対側へ跳ばない）。距離は中立へ。

private let behind = Rotation(yaw: .pi, pitch: 0, roll: 0)
private let frame = 1.0 / 15

/// 同じ目標で `frames` 回進め、各フレームの出力を集める。
private func run(
  _ blend: inout TrackingBlend, _ target: TrackingBlend.Target, frames: Int
) -> [(rotation: Rotation, distanceRatio: Double)] {
  (0..<frames).map { _ in blend.advance(target, dt: frame) }
}

private func yawTurn(_ yaw: Double) -> Rotation {
  Rotation(yaw: yaw, pitch: 0, roll: 0)
}

/// 真後ろに着く前までの yaw の列。着いた瞬間は ±π のどちらにもなりうるので除く。
private func yawsBeforeBehind(_ outputs: [(rotation: Rotation, distanceRatio: Double)]) -> [Double] {
  outputs.filter { $0.rotation.angle(to: behind) > 1e-3 }.map { $0.rotation.eulerAngles.yaw }
}

/// 追跡していた向きから後ろ向きになったときの、真後ろに着くまでの yaw。
private func yawsTurningAway(from tracked: Rotation) -> [Double] {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(tracked, distanceRatio: nil), frames: 15)
  return yawsBeforeBehind(run(&blend, .facingAway, frames: 20))
}

@Test("後ろ向きが続けば、正面に対して真後ろ（yaw 180°・pitch/roll 0）に達する")
func facingAwayReachesBehind() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(Rotation(yaw: 0.5, pitch: 0.2, roll: 0.1), distanceRatio: nil), frames: 15)
  let last = run(&blend, .facingAway, frames: 20).last!
  #expect(last.rotation.angle(to: behind) < 1e-6)
  let euler = last.rotation.eulerAngles
  #expect(abs(euler.pitch) < 1e-6)
  #expect(abs(euler.roll) < 1e-6)
}

@Test("正の yaw へ振り向いていったなら、正の側を通って真後ろへ回る", arguments: [0.7, 1.2])
func turnsThroughThePositiveSide(yaw: Double) {
  let yaws = yawsTurningAway(from: yawTurn(yaw))
  #expect(!yaws.isEmpty)
  #expect(yaws.allSatisfy { $0 > 0 })
  #expect(yaws.contains { (1.2...2.0).contains($0) }, "真横（π/2）を通ること")
}

@Test("負の yaw へ振り向いていったなら、負の側を通って真後ろへ回る", arguments: [-0.7, -1.2])
func turnsThroughTheNegativeSide(yaw: Double) {
  let yaws = yawsTurningAway(from: yawTurn(yaw))
  #expect(!yaws.isEmpty)
  #expect(yaws.allSatisfy { $0 < 0 })
  #expect(yaws.contains { (-2.0 ... -1.2).contains($0) }, "真横（-π/2）を通ること")
}

@Test("最後の yaw が正面に近く向きが曖昧なら、正の側を通る（決め打ち）", arguments: [0.05, 0.0, -0.05])
func ambiguousYawTurnsThroughThePositiveSide(yaw: Double) {
  let yaws = yawsTurningAway(from: yawTurn(yaw))
  #expect(!yaws.contains { (-2.8 ... -0.3).contains($0) }, "負の側を通らないこと")
  #expect(yaws.contains { (1.2...2.0).contains($0) })
}

@Test("後ろへは一気に飛ばず、途中の値を通って回る")
func turnsGradually() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.5), distanceRatio: nil), frames: 15)
  let turning = run(&blend, .facingAway, frames: 12)
  // 1フレーム目はまだ追跡していた向きの近く。
  #expect(turning[0].rotation.angle(to: behind) > 2.0)
  // 回り始めて 0.4 秒（既定 0.8 秒の半分）で、おおよそ真横。
  let halfway = turning[5].rotation.eulerAngles.yaw
  #expect(halfway > 1.0 && halfway < 2.6, "途中の値を通ること (実測 \(halfway))")
}

@Test("顔が戻ったら、その場で戻り始め、程なく追跡値に達する")
func faceReturnBringsTrackingBack() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.7), distanceRatio: nil), frames: 15)
  _ = run(&blend, .facingAway, frames: 30)
  let back = yawTurn(-0.4)
  let returning = run(&blend, .tracked(back, distanceRatio: nil), frames: 15)
  #expect(returning[0].rotation.angle(to: behind) > 1e-3, "戻ってきた最初のフレームで動き出すこと")
  #expect(returning.last!.rotation.angle(to: back) < 1e-6)
}

@Test("戻りは、戻ってきた顔の側を通る（出ていった側ではない）")
func returnTakesTheSideOfTheReturningFace() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.7), distanceRatio: nil), frames: 15)
  _ = run(&blend, .facingAway, frames: 30)
  let yaws = yawsBeforeBehind(run(&blend, .tracked(yawTurn(-0.7), distanceRatio: nil), frames: 15))
  #expect(!yaws.contains { (0.3...2.8).contains($0) }, "正の側を通らないこと")
  #expect(yaws.contains { (-2.2 ... -1.0).contains($0) })
}

@Test("戻りの途中で、顔の yaw が 0 の付近で揺れても音場は反対側へ跳ばない")
func jitterNearZeroDoesNotFlipTheReturn() {
  var blend = TrackingBlend(turn: FacingAwayTurn(turnAway: 0.8, turnBack: 1.0))
  _ = run(&blend, .tracked(yawTurn(0.7), distanceRatio: nil), frames: 15)
  _ = run(&blend, .facingAway, frames: 30)
  var previous = behind
  for index in 0..<20 {
    let jitter = index.isMultiple(of: 2) ? 0.02 : -0.02
    let (rotation, _) = blend.advance(.tracked(yawTurn(jitter), distanceRatio: nil), dt: frame)
    #expect(rotation.angle(to: previous) < 0.5, "フレーム \(index) で跳んだ")
    previous = rotation
  }
}

@Test("回る途中で顔が戻ったら、反対側の顔でも来た道を引き返す（反対側へ跳ばない）")
func reversingMidTurnRetracesThePath() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.7), distanceRatio: nil), frames: 15)
  // 正の側を回って、半分（真横の先）まで来たところ。
  var previous = run(&blend, .facingAway, frames: 6).last!.rotation
  #expect(previous.eulerAngles.yaw > 1.2)
  // 顔ははっきり負の側に戻ってくる。ここで側を決め直すと、出力は負の側の経路へ
  // 乗り換わって 180° 近く跳ぶ。
  let returning = run(&blend, .tracked(yawTurn(-0.5), distanceRatio: nil), frames: 15)
  for output in returning {
    // 土台そのものは、復帰した顔の位置へ重み分だけ跳ぶ（従来からのロスト復帰の振る舞い）。
    // 経路の乗り換えはそれより桁違いに大きいので、緩い上限で見分けられる。
    #expect(output.rotation.angle(to: previous) < 1.5)
    previous = output.rotation
  }
  #expect(!returning.map { $0.rotation.eulerAngles.yaw }.contains { (-2.8 ... -1.0).contains($0) })
  #expect(returning.last!.rotation.angle(to: yawTurn(-0.5)) < 1e-6)
}

@Test("後ろ向きの間、距離比は中立（1.0）へ戻る — 瞳の間隔は測れなくなるため")
func facingAwayNeutralisesDistance() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.3), distanceRatio: 1.8), frames: 15)
  let away = run(&blend, .facingAway, frames: 40)
  #expect(away[0].distanceRatio > 1.5, "一気には戻さない")
  #expect(abs(away.last!.distanceRatio - 1.0) < 1e-9)
}

@Test("後ろ向きの後に誰もいなくなれば、正面へ戻る")
func lostAfterFacingAwayReturnsToFront() {
  var blend = TrackingBlend()
  _ = run(&blend, .tracked(yawTurn(0.7), distanceRatio: nil), frames: 15)
  _ = run(&blend, .facingAway, frames: 30)
  #expect(!blend.isNeutral, "真後ろへ回っている間は中立ではない")
  let last = run(&blend, .lost, frames: 45).last!
  #expect(last.rotation.angle(to: .identity) < 1e-6)
  #expect(blend.isNeutral)
}

@Test("従来の呼び方（tracked: nil）はロストのまま — 後ろへは回らない")
func legacyNilIsLostNotFacingAway() {
  var blend = TrackingBlend()
  for _ in 0..<15 {
    _ = blend.advance(tracked: yawTurn(0.7), distanceRatio: nil, dt: frame)
  }
  var output = Rotation.identity
  for _ in 0..<45 {
    (output, _) = blend.advance(tracked: nil, distanceRatio: nil, dt: frame)
  }
  #expect(output.angle(to: .identity) < 1e-6)
}
