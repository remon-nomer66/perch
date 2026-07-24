import AVFoundation
import Foundation
import SpatialAudioKit

// HRTF 空間化の発音確認用プローブ。
//
// 広帯域ノイズ（前後・上下の定位がトーンより格段に分かりやすい）を鳴らしながら、
// 横方向（リスナーを回す）と縦方向（音場を上下に傾ける）を順に試す。各ステップで
// 「今どこに聞こえるべきか」を表示するので、実際の聞こえと突き合わせて定位の効きと
// 軸の向きの規約を確かめられる。頭部追従（フェーズ2）はこの経路へカメラ由来の値を流す。
// 実機・ヘッドホンで実行する。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// リスナー向き（度）から、前方固定の音源が相対的にどこへ聞こえるはずかの粗いラベル。
func bearingLabel(yawDegrees: Double) -> String {
  let y = (yawDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
  switch y {
  case 0..<45, 315..<360: return "正面あたり"
  case 45..<135, 225..<315: return "真横あたり"
  default: return "真後ろ（後頭部）あたり"
  }
}

/// 音場の仰角（度）から、上下どこへ聞こえるはずかのラベル。
func elevationLabel(degrees: Double) -> String {
  switch degrees {
  case 45...: return "上（頭の上あたり）"
  case 15..<45: return "やや上"
  case -15..<15: return "正面（水平）"
  case -45..<(-15): return "やや下"
  default: return "下（足元あたり）"
  }
}

/// 指定した仰角（度）の音場設定を作る。
func parameters(elevationDegrees: Double) -> SpatialAudioParameters {
  let elevation = elevationDegrees * .pi / 180
  return SpatialAudioParameters(
    isEnabled: true,
    field: StereoField(spread: StereoField.defaultSpread, elevation: elevation, distance: 1),
    quality: .high
  )
}

let sampleRate = 48_000.0
let frameCount = Int(sampleRate)  // 約 1 秒ぶんのノイズをループ

let graph: SpatialAudioGraph
do {
  graph = try SpatialAudioGraph(sampleRate: sampleRate)
} catch {
  fail("グラフ初期化に失敗: \(error)")
}

let samples = NoiseGenerator.white(frameCount: frameCount)
guard let noise = graph.makeMonoBuffer(samples) else {
  fail("ノイズバッファ生成に失敗")
}
graph.apply(parameters(elevationDegrees: 0))
graph.scheduleLooping(left: noise, right: noise)

do {
  try graph.start()
} catch {
  fail("エンジン開始に失敗: \(error)")
}

print("HRTF 空間化ノイズを再生中。ヘッドホン／イヤホンを既定の出力にしてください。")
print("Ctrl-C で停止。\n")

// 開始位置＝正面をはっきりさせる。
graph.updateListener(.forward)
print("開始: listener yaw = 0° → 正面あたり")
Thread.sleep(forTimeInterval: 3.0)

while true {
  // ── 横方向（左右）: 一番強く効く ──
  print("\n― 横方向（左右）: リスナーを回します。一番強く効きます ―")
  graph.apply(parameters(elevationDegrees: 0))
  for yawDegrees in stride(from: 30.0, through: 330.0, by: 30.0) {
    graph.updateListener(ListenerOrientation(yaw: yawDegrees * .pi / 180, pitch: 0, roll: 0))
    print(String(format: "listener yaw = %3.0f° → %@", yawDegrees, bearingLabel(yawDegrees: yawDegrees)))
    Thread.sleep(forTimeInterval: 2.0)
  }
  graph.updateListener(.forward)

  // ── 縦方向（上下）: 音場を傾ける。汎用HRTFでは控えめ ──
  print("\n― 縦方向（上下）: 音場を傾けます。汎用HRTFでは横より控えめです ―")
  print("  （※低域は無指向性なので、上下に振っても“下”には聞こえません）")
  for elevationDegrees in [60.0, 30.0, 0.0, -30.0, -60.0, -30.0, 0.0, 30.0] {
    graph.apply(parameters(elevationDegrees: elevationDegrees))
    print(String(format: "field elevation = %4.0f° → %@", elevationDegrees, elevationLabel(degrees: elevationDegrees)))
    Thread.sleep(forTimeInterval: 2.0)
  }
  graph.apply(parameters(elevationDegrees: 0))
}
