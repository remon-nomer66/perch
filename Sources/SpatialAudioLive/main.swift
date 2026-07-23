import AVFoundation
import Darwin
import Foundation
import SpatialAudioKit

// システム音のリアルタイム空間化（本命）。
//
//   引数 multiband : マルチバンド+M/S 空間化（本命）。低音は中央で固く、中高域の
//                    左右成分を広げる。ミックスの楽器パンを尊重して立体化。
//   引数 tune     : 対話調整モード。再生しながらキー操作で音場を追い込む。
//   引数 rotate   : リスナーの向きをゆっくり回す効果デモ。
//   引数 nomute   : 原音をミュートしない（原音＋空間化版を同時に鳴らして比較）。
// 実機・ヘッドホンで実行する。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

// 端末の生入力（1キーずつ取得）。終了時と割り込み時に必ず元へ戻す。
nonisolated(unsafe) var savedTermios = termios()
nonisolated(unsafe) var rawEnabled = false

func enableRawInput() {
  tcgetattr(STDIN_FILENO, &savedTermios)
  var raw = savedTermios
  raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
  tcsetattr(STDIN_FILENO, TCSANOW, &raw)
  rawEnabled = true
}

func disableRawInput() {
  if rawEnabled {
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    rawEnabled = false
  }
}

@available(macOS 14.4, *)
func runLive() -> Never {
  let arguments = Set(CommandLine.arguments.dropFirst())
  let multiband = arguments.contains("multiband")
  let tune = arguments.contains("tune")
  let rotate = arguments.contains("rotate")
  // 既定は空間化版だけを流す（調整・本番とも耳で判断しやすい）。nomute で無効化。
  let muteOriginal = !arguments.contains("nomute")

  if multiband {
    runMultiband(muteOriginal: muteOriginal)
  }

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

  if tune {
    runTuner(live)
  } else if rotate {
    runRotateDemo(live)
  } else {
    print("正面固定で空間化中。Ctrl-C で停止。")
    while true { Thread.sleep(forTimeInterval: 1.0) }
  }
}

@available(macOS 14.4, *)
func runMultiband(muteOriginal: Bool) -> Never {
  let spatializer: MultibandSpatializer
  do {
    spatializer = try MultibandSpatializer(muteOriginal: muteOriginal)
  } catch {
    fail("マルチバンド初期化に失敗: \(error)")
  }
  do {
    try spatializer.start()
  } catch {
    fail("開始に失敗: \(error)")
  }

  let format = spatializer.captureFormat
  print("マルチバンド + M/S 空間化中。")
  print(String(format: "  取得フォーマット: %.0f Hz / %u ch", format.mSampleRate, format.mChannelsPerFrame))
  if muteOriginal {
    print("  原音はミュート中。低音は中央で固く、中高域の左右成分を広げています。")
  } else {
    print("  原音ミュートなし（原音＋空間化版）。")
  }
  print("何か音楽を再生してください。Ctrl-C で停止。")
  while true { Thread.sleep(forTimeInterval: 1.0) }
}

@available(macOS 14.4, *)
func runRotateDemo(_ live: LiveSpatializer) -> Never {
  print("向きをゆっくり回します（効果デモ）。Ctrl-C で停止。\n")
  var yaw = 0.0
  while true {
    live.updateListener(ListenerOrientation(yaw: yaw * .pi / 180, pitch: 0, roll: 0))
    print(String(format: "\rlistener yaw = %3.0f°", yaw), terminator: "")
    fflush(stdout)
    yaw += 15
    if yaw >= 360 { yaw -= 360 }
    Thread.sleep(forTimeInterval: 1.5)
  }
}

// MARK: - 対話調整モード

@available(macOS 14.4, *)
func runTuner(_ live: LiveSpatializer) -> Never {
  // 割り込みでも端末を必ず戻す。
  signal(SIGINT) { _ in
    disableRawInput()
    _exit(0)
  }

  var spreadDegrees = 30.0  // 中央から左右各スピーカーまでの開き角
  var distance = 1.0        // メートル
  var elevationDegrees = 0.0
  var aimDegrees = 0.0      // 音場全体の向き（リスナーの yaw）

  func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

  func apply() {
    let field = StereoField(
      spread: spreadDegrees * .pi / 180,
      elevation: elevationDegrees * .pi / 180,
      distance: distance
    )
    live.apply(SpatialAudioParameters(isEnabled: true, field: field, quality: .high))
    live.updateListener(ListenerOrientation(yaw: aimDegrees * .pi / 180, pitch: 0, roll: 0))
    print(
      String(
        format: "\r幅=±%2.0f°  距離=%.2fm  高さ=%+3.0f°  向き=%+4.0f°        ",
        spreadDegrees, distance, elevationDegrees, aimDegrees
      ),
      terminator: ""
    )
    fflush(stdout)
  }

  print("""

    ── 調整モード ──  音を鳴らしながらキーで音場を動かせます。
      幅   : [ 狭く   ] 広く
      距離 : - 近く   = 遠く
      高さ : s 下げる w 上げる
      向き : a 左へ   d 右へ
      r 既定に戻す    p 現在値を確定表示    q 終了
    """)
  apply()

  enableRawInput()
  defer { disableRawInput() }

  var byte: UInt8 = 0
  while read(STDIN_FILENO, &byte, 1) == 1 {
    switch Character(UnicodeScalar(byte)) {
    case "[": spreadDegrees = clamp(spreadDegrees - 5, 0, 90)
    case "]": spreadDegrees = clamp(spreadDegrees + 5, 0, 90)
    case "-", "_": distance = clamp(distance - 0.25, 0.25, 5)
    case "=", "+": distance = clamp(distance + 0.25, 0.25, 5)
    case "s": elevationDegrees = clamp(elevationDegrees - 5, -80, 80)
    case "w": elevationDegrees = clamp(elevationDegrees + 5, -80, 80)
    case "a": aimDegrees = clamp(aimDegrees - 5, -180, 180)
    case "d": aimDegrees = clamp(aimDegrees + 5, -180, 180)
    case "r":
      spreadDegrees = 30; distance = 1; elevationDegrees = 0; aimDegrees = 0
    case "p":
      print(
        String(
          format: "\n確定値: 幅=±%2.0f° 距離=%.2fm 高さ=%+3.0f° 向き=%+4.0f°",
          spreadDegrees, distance, elevationDegrees, aimDegrees
        )
      )
    case "q":
      disableRawInput()
      live.stop()
      print("\n終了しました。")
      exit(0)
    default:
      continue
    }
    apply()
  }
  disableRawInput()
  live.stop()
  exit(0)
}

if #available(macOS 14.4, *) {
  runLive()
} else {
  fail("Core Audio プロセスタップは macOS 14.4 以降が必要です。")
}
