import AudioToolbox
import Foundation
import SpatialAudioKit

// システム音声キャプチャの確認用プローブ（発音はしない）。
//
// Core Audio プロセスタップでシステム全体の音を取得し、入力レベルを表示するだけ。
// 何か音楽・動画を再生しながら実行し、メータが振れれば「取得成功」。
// 全く振れない／エラーコードが出るなら、署名・権限（NSAudioCaptureUsageDescription）の
// 問題であり、その OSStatus を手がかりに次の手を決める。原音はミュートしないので、
// 実行中もそのまま音は聞こえる。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// オーディオスレッドとメインスレッドの間でピーク値を安全に受け渡す小箱。
final class LevelBox: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: Float = 0
  func report(_ value: Float) {
    lock.lock()
    if value > peak { peak = value }
    lock.unlock()
  }
  func takePeak() -> Float {
    lock.lock()
    let value = peak
    peak = 0
    lock.unlock()
    return value
  }
}

func meterBar(peak: Float) -> String {
  let width = 40
  let db = peak > 0 ? 20 * log10(Double(peak)) : -120
  // -60dB..0dB を 0..width にマップ。
  let filled = max(0, min(width, Int((db + 60) / 60 * Double(width))))
  let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
  return String(format: "[%@] %6.1f dB", bar, db)
}

@available(macOS 14.4, *)
func runCaptureProbe() -> Never {
  let level = LevelBox()

  let tap = SystemAudioTap { bufferListPointer in
    let buffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: bufferListPointer)
    )
    var peak: Float = 0
    for buffer in buffers {
      guard let raw = buffer.mData else { continue }
      let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
      let samples = raw.assumingMemoryBound(to: Float.self)
      for index in 0..<count {
        let magnitude = abs(samples[index])
        if magnitude > peak { peak = magnitude }
      }
    }
    level.report(peak)
  }

  do {
    try tap.start()
  } catch {
    fail("タップ開始に失敗: \(error)")
  }

  let format = tap.streamFormat
  print("システム音声のキャプチャを開始しました。")
  print(String(format: "  取得フォーマット: %.0f Hz / %u ch", format.mSampleRate, format.mChannelsPerFrame))
  print("何か音楽・動画を再生してください。メータが振れれば取得成功です。Ctrl-C で停止。\n")

  while true {
    Thread.sleep(forTimeInterval: 0.25)
    print("\r" + meterBar(peak: level.takePeak()), terminator: "")
    fflush(stdout)
  }
}

if #available(macOS 14.4, *) {
  runCaptureProbe()
} else {
  fail("Core Audio プロセスタップは macOS 14.4 以降が必要です。")
}
