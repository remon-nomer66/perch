import AVFoundation
import Foundation
import SpatialAudioKit

// HRTF 空間化の発音確認用プローブ。
//
// トーンを鳴らしながらリスナーの向きを 30° ずつ回し、音像が頭の周りを回るかを
// 耳で確かめる。これは頭部追従（フェーズ2）が将来ここへ流し込む値と同じ経路を、
// 権限の要らないトーンで先に検証するためのもの。実機・ヘッドホンで実行する。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let sampleRate = 48_000.0
let frequency = 440.0
// ループ時のプチノイズを避けるため、整数周期ぶんの長さにする。
let periodFrames = Int((sampleRate / frequency).rounded())
let frameCount = periodFrames * 200  // 約 0.9 秒

let graph: SpatialAudioGraph
do {
  graph = try SpatialAudioGraph(sampleRate: sampleRate)
} catch {
  fail("グラフ初期化に失敗: \(error)")
}

graph.apply(
  SpatialAudioParameters(isEnabled: true, field: StereoField(), quality: .high)
)

let samples = ToneGenerator.sine(
  frequency: frequency, sampleRate: sampleRate, frameCount: frameCount
)
guard let tone = graph.makeMonoBuffer(samples) else {
  fail("トーンバッファ生成に失敗")
}
graph.scheduleLooping(left: tone, right: tone)

do {
  try graph.start()
} catch {
  fail("エンジン開始に失敗: \(error)")
}

print("HRTF 空間化トーンを再生中。ヘッドホンを既定の出力にしてください。")
print("リスナーの向きを 30° ずつ回します。音像が頭の周りを回れば成功。Ctrl-C で停止。")

var yawDegrees = 0.0
while true {
  let yaw = yawDegrees * .pi / 180
  graph.updateListener(ListenerOrientation(yaw: yaw, pitch: 0, roll: 0))
  print(String(format: "listener yaw = %4.0f°", yawDegrees))
  yawDegrees += 30
  if yawDegrees >= 360 { yawDegrees -= 360 }
  Thread.sleep(forTimeInterval: 1.5)
}
