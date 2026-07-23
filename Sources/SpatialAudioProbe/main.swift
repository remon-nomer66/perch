import AVFoundation
import Foundation
import SpatialAudioKit

// HRTF 空間化の発音確認用プローブ。
//
// 広帯域ノイズ（前後の定位がトーンより格段に分かりやすい）を鳴らしながら、
// リスナーの向きを 30° ずつ回す。各ステップで「今どこに聞こえるべきか」を表示するので、
// 実際の聞こえと突き合わせて、前後の定位と回転方向（＝軸の向きの規約）を確かめられる。
// 頭部追従（フェーズ2）はこの listener 向きへカメラ由来の値を流す。実機・ヘッドホンで実行する。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// リスナー向き（度）から、前方固定の音源が相対的にどこへ聞こえるはずかの粗いラベル。
/// 前後・真横は軸の左右規約に依らないので、まず前後定位の確認に使える。
func bearingLabel(yawDegrees: Double) -> String {
  let y = (yawDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
  switch y {
  case 0..<45, 315..<360: return "正面あたり"
  case 45..<135, 225..<315: return "真横あたり"
  default: return "真後ろ（後頭部）あたり"
  }
}

let sampleRate = 48_000.0
let frameCount = Int(sampleRate)  // 約 1 秒ぶんのノイズをループ

let graph: SpatialAudioGraph
do {
  graph = try SpatialAudioGraph(sampleRate: sampleRate)
} catch {
  fail("グラフ初期化に失敗: \(error)")
}

graph.apply(
  SpatialAudioParameters(isEnabled: true, field: StereoField(), quality: .high)
)

let samples = NoiseGenerator.white(frameCount: frameCount)
guard let noise = graph.makeMonoBuffer(samples) else {
  fail("ノイズバッファ生成に失敗")
}
graph.scheduleLooping(left: noise, right: noise)

do {
  try graph.start()
} catch {
  fail("エンジン開始に失敗: \(error)")
}

print("HRTF 空間化ノイズを再生中。ヘッドホン／イヤホンを既定の出力にしてください。")
print("まず正面で数秒保持し、その後 30° ずつ回します。表示と実際の聞こえを比べてください。")
print("Ctrl-C で停止。\n")

// まず正面でしばらく保持して「開始位置＝正面」をはっきりさせる。
graph.updateListener(.forward)
print("listener yaw =   0° → 正面あたり（開始位置）")
Thread.sleep(forTimeInterval: 3.0)

var yawDegrees = 30.0
while true {
  let yaw = yawDegrees * .pi / 180
  graph.updateListener(ListenerOrientation(yaw: yaw, pitch: 0, roll: 0))
  print(String(format: "listener yaw = %3.0f° → %@", yawDegrees, bearingLabel(yawDegrees: yawDegrees)))
  yawDegrees += 30
  if yawDegrees >= 360 { yawDegrees -= 360 }
  Thread.sleep(forTimeInterval: 2.0)
}
