import Foundation
import Testing

@testable import SpatialAudioKit

// 後ろ向きの切り替えの約束: 入るのは「後ろ向き」が途切れずに続いてから、出るのは
// 顔が戻ったら即座に、判定できないフレームが続いたら少し待ってから。入りにくく
// 出にくい側に倒して、体の点の揺れで音場が前後に点滅しないようにする。

/// 1文字が1フレーム（15fps）: F = 顔（回転あり）、A = 後ろ向き、U = 判定不能、
/// V = 顔は見えたが姿勢角が無い。
private func run(_ frames: String, gate: FacingAwayGate = FacingAwayGate()) -> FacingAwayGate.Mode {
  var gate = gate
  var mode = gate.mode
  for (index, frame) in frames.enumerated() {
    let time = Double(index) / 15
    let sample: HeadPoseSample =
      switch frame {
      case "F":
        HeadPoseSample(time: time, rotation: .identity, pixelIPD: 60, faceWidth: 200)
      case "A":
        .facingAway(time: time)
      case "V":
        HeadPoseSample(time: time, rotation: nil, pixelIPD: nil, faceWidth: 180, presence: .faceVisible)
      default:
        HeadPoseSample(time: time, rotation: nil, pixelIPD: nil, faceWidth: nil)
      }
    mode = gate.update(with: sample, dt: 1.0 / 15)
  }
  return mode
}

private func frames(_ frame: Character, _ count: Int) -> String {
  String(repeating: frame, count: count)
}

/// 追跡から 0.4 秒ぶんの後ろ向きで、後ろ向きに入ったところ。
private let entered: String = "F" + frames("A", 6)

private let gateCases: [(frames: String, expected: FacingAwayGate.Mode)] = [
  ("F", .tracking),
  ("FU", .lost),
  ("FV", .lost),
  // 後ろ向きでも 0.4 秒続くまでは見失いのまま（従来どおり）。
  ("FAAAAA", .lost),
  (entered, .facingAway),
  // 途中で一度でも判定不能が挟まれば数え直す。
  ("FAAAUAAA", .lost),
  ("FAAAVAAA", .lost),
  // 顔が戻ったら即座に追跡へ。
  (entered + "F", .tracking),
  // 後ろ向きの間の判定不能は、1 秒続くまでは後ろ向きのまま。
  (entered + frames("U", 14), .facingAway),
  (entered + frames("U", 15), .lost),
  // 顔は見えたが姿勢角が無いフレームも、後ろ向きの根拠にはならない（同じく 1 秒で解除）。
  (entered + frames("V", 15), .lost),
  // 後ろ向きのフレームが挟まれば、解除の待ちは数え直す。
  (entered + frames("U", 10) + "A" + frames("U", 10), .facingAway),
  // 解除の後に入り直すには、また 0.4 秒続く必要がある。
  (entered + frames("U", 15) + frames("A", 5), .lost),
  (entered + frames("U", 15) + frames("A", 6), .facingAway),
]

@Test("フレーム列と、最後のフレームの後のモード", arguments: gateCases)
func gateFollowsTheFrames(frames: String, expected: FacingAwayGate.Mode) {
  #expect(run(frames) == expected)
}

@Test("入りと解除の待ち時間は指定できる")
func delaysAreConfigurable() {
  let quick = FacingAwayGate(enterAfter: 0.2, releaseAfter: 0.2)
  #expect(run("FAAA", gate: quick) == .facingAway)
  #expect(run("FAAAUUU", gate: quick) == .lost)
}

@Test("作りたては見失い扱い（まだ何も見ていない）")
func startsLost() {
  #expect(FacingAwayGate().mode == .lost)
}
