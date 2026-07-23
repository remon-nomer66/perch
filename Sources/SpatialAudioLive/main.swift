import AVFoundation
import Foundation
import SpatialAudioKit

// システム音のリアルタイム空間化（本命）。
//
// システム全体の音を取り込み、HRTF 空間化して出力する。既定では原音をミュートし、
// 空間化版だけを流す（＝音楽が「頭の外・前方」に広がって聞こえれば成功）。
//   引数 nomute : 原音をミュートしない（原音と空間化版を同時に鳴らして比較。二重に
//                 聞こえるのは正常）。
//   引数 rotate : リスナーの向きをゆっくり回す（空間化が効いているか分かりやすい）。
// 実機・ヘッドホンで実行する。取得音がフル帯域なので、ノイズより効果が分かりやすい。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

@available(macOS 14.4, *)
func runLive() -> Never {
  let arguments = Set(CommandLine.arguments.dropFirst())
  let muteOriginal = !arguments.contains("nomute")
  let rotate = arguments.contains("rotate")

  let live: LiveSpatializer
  do {
    live = try LiveSpatializer(
      parameters: SpatialAudioParameters(isEnabled: true, field: StereoField(), quality: .high),
      muteOriginal: muteOriginal
    )
  } catch {
    fail("初期化に失敗: \(error)")
  }

  do {
    try live.start()
  } catch {
    fail("開始に失敗: \(error)")
  }

  let format = live.captureFormat
  print("システム音のリアルタイム空間化を開始しました。")
  print(String(format: "  取得フォーマット: %.0f Hz / %u ch", format.mSampleRate, format.mChannelsPerFrame))
  if muteOriginal {
    print("  原音はミュート中。空間化版だけが流れます（音が消えたら Ctrl-C で復帰）。")
  } else {
    print("  原音ミュートなし。原音＋空間化版が同時に鳴ります（二重は正常）。")
  }
  print("何か音楽・動画を再生してください。前方・頭の外に広がれば成功。Ctrl-C で停止。\n")

  var yawDegrees = 0.0
  while true {
    if rotate {
      live.updateListener(ListenerOrientation(yaw: yawDegrees * .pi / 180, pitch: 0, roll: 0))
      print(String(format: "\rlistener yaw = %3.0f°", yawDegrees), terminator: "")
      fflush(stdout)
      yawDegrees += 15
      if yawDegrees >= 360 { yawDegrees -= 360 }
      Thread.sleep(forTimeInterval: 1.5)
    } else {
      // 正面固定（フェーズ1）。プロセスを生かし続けるだけ。
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
}

if #available(macOS 14.4, *) {
  runLive()
} else {
  fail("Core Audio プロセスタップは macOS 14.4 以降が必要です。")
}
