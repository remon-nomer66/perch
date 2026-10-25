import Foundation
import SpatialAudioKit

@testable import Perch

// ヘッドトラッキングのテストが共有するフェイク。実カメラ・実デバイス一覧に触れずに、
// 観測の流し込みとカメラの抜き差しをテストから起こす。

/// テストから手で観測を流し込めるプロバイダ。
final class FakeHeadPoseProvider: HeadPoseProvider, @unchecked Sendable {
  let samples: AsyncStream<HeadPoseSample>
  let continuation: AsyncStream<HeadPoseSample>.Continuation
  private let startError: (any Error)?
  private let holdsStart: Bool
  private let lock = NSLock()
  private var startGate: CheckedContinuation<Void, Never>?
  private(set) var started = false
  private(set) var stopped = false

  /// - Parameter holdsStart: true なら start() は `releaseStart()` まで返らない
  ///   （起動に時間のかかるカメラ・開いている最中の出来事を作る）。
  init(startError: (any Error)? = nil, holdsStart: Bool = false) {
    self.startError = startError
    self.holdsStart = holdsStart
    // 実物は最新値のみ保持だが、テストは流した観測を全部処理してほしいので無制限。
    (samples, continuation) = AsyncStream.makeStream(of: HeadPoseSample.self)
  }

  /// start() が `releaseStart()` 待ちで止まっている。
  var isHoldingStart: Bool {
    lock.withLock { startGate != nil }
  }

  func start() async throws {
    started = true
    if holdsStart {
      await withCheckedContinuation { gate in
        lock.withLock { startGate = gate }
      }
    }
    if let startError { throw startError }
  }

  func releaseStart() {
    let gate = lock.withLock {
      defer { startGate = nil }
      return startGate
    }
    gate?.resume()
  }

  func stop() {
    stopped = true
    continuation.finish()
  }
}

/// 接続・切断をテストから起こせるカメラ一覧。
@MainActor
final class FakeCameraCatalog: CameraCatalog {
  /// いま列挙すると返る一覧。通知なしで書き換えれば「列挙だけが先に変わった」状態を作れる。
  var cameras: [CameraDevice]
  var onChange: (@MainActor ([CameraDevice]) -> Void)?
  /// 列挙された回数（同期・非同期の合計）。起動時に列挙しないことの確認に使う。
  private(set) var enumerations = 0

  init(_ cameras: [CameraDevice]) {
    self.cameras = cameras
  }

  /// true なら loadCameras() は `releaseLoad(with:)` まで返らない（裏の読み込み中に
  /// 通知や開く操作が割り込む、を作る）。
  var holdsLoad = false
  private var loadGate: CheckedContinuation<[CameraDevice], Never>?
  var isHoldingLoad: Bool { loadGate != nil }

  func currentCameras() -> [CameraDevice] {
    enumerations += 1
    return cameras
  }

  func loadCameras() async -> [CameraDevice] {
    guard holdsLoad else { return currentCameras() }
    enumerations += 1
    return await withCheckedContinuation { loadGate = $0 }
  }

  /// 止めていた読み込みを、この一覧（古いかもしれない）で返す。
  func releaseLoad(with cameras: [CameraDevice]) {
    loadGate?.resume(returning: cameras)
    loadGate = nil
  }

  /// 抜き差しの通知つきで一覧を差し替える。
  func send(_ cameras: [CameraDevice]) {
    self.cameras = cameras
    onChange?(cameras)
  }
}

enum TestCameras {
  static let builtIn = CameraDevice(id: "builtin", name: "Built-in", kind: .builtIn)
  static let webcam = CameraDevice(id: "webcam", name: "Webcam", kind: .external)
  static let otherWebcam = CameraDevice(id: "webcam-2", name: "Webcam 2", kind: .external)
}
