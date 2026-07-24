import AVFoundation
import Vision

/// 内蔵カメラ + Vision による頭部姿勢プロバイダ。
///
/// - 生フレームは専用シリアルキューの外に出ない。外へ渡るのは `HeadPoseSample`
///   （Sendable な値）だけ。可変状態（追跡中の顔枠・見失いカウント）も同じキューでしか
///   触らないため `@unchecked Sendable`。
/// - キューは**全インスタンス共有**の1本。旧セッションの停止と新セッションの構成が
///   同じ物理カメラを別コンテキストから掴んで競合しないよう、開始・停止・構成は
///   すべてこの1本の上で直列になる（素早い OFF→ON でも 停止→構成 の順が保たれる）。
/// - 推論は同時に1本（デリゲートがシリアルキューで同期実行）。遅れたフレームは
///   `alwaysDiscardsLateVideoFrames` で捨て、遅延を溜めない。
/// - カメラは内蔵を明示して選ぶ。Continuity Camera（iPhone）が勝手に立ち上がる事故を防ぐ。
/// - カメラが外部要因で死んだら（他プロセスに取られた・切断・ランタイムエラー）、
///   ストリームを終える。呼び出し側はストリームの終端を「カメラが止まった」と読む。
public final class CameraHeadPoseProvider: NSObject, HeadPoseProvider, @unchecked Sendable {
  public enum ProviderError: Error, Equatable {
    case notAuthorized
    case noBuiltInCamera
    case cannotConfigure
  }

  /// 全インスタンス共有の直列実行路。構成・開始・停止・フレーム処理はすべてこの上。
  private static let sessionQueue = DispatchQueue(
    label: "SpatialAudioKit.CameraHeadPose", qos: .userInitiated
  )

  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let conversion: VisionPoseConversion
  private let continuation: AsyncStream<HeadPoseSample>.Continuation
  public let samples: AsyncStream<HeadPoseSample>

  // 以下の可変状態は `sessionQueue` でのみ触る。
  private var trackedBox: CGRect?
  private var missCount = 0
  private var runtimeErrorObserver: (any NSObjectProtocol)?
  /// 見失いがこのフレーム数続いたら、追っていた顔を諦めて最大の顔から取り直す。
  /// 15fps で約3秒 — 通りすがりの顔へ即座に飛ばないための猶予。
  private let reacquireAfterMisses = 45

  public init(conversion: VisionPoseConversion = .assumed) {
    self.conversion = conversion
    (samples, continuation) = AsyncStream.makeStream(
      of: HeadPoseSample.self, bufferingPolicy: .bufferingNewest(1)
    )
    super.init()
  }

  deinit {
    // 通常経路は stop() を通るが、通らず手放された場合もカメラを回したままにしない。
    if let runtimeErrorObserver {
      NotificationCenter.default.removeObserver(runtimeErrorObserver)
    }
    let box = SessionBox(session: session)
    Self.sessionQueue.async {
      if box.session.isRunning {
        box.session.stopRunning()
      }
    }
    continuation.finish()
  }

  public static var authorization: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .video)
  }

  public static func requestAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .video)
  }

  /// 構成と起動を共有キュー上で行い、実際に走り出す（か失敗が確定する）まで返らない。
  /// `commitConfiguration` も `startRunning` もブロッキングなので、メインでは待つだけ。
  public func start() async throws {
    guard Self.authorization == .authorized else { throw ProviderError.notAuthorized }
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      Self.sessionQueue.async { [self] in
        do {
          try configureAndRun()
          ready.resume()
        } catch {
          ready.resume(throwing: error)
        }
      }
    }
  }

  public func stop() {
    Self.sessionQueue.async { [self] in
      if let runtimeErrorObserver {
        NotificationCenter.default.removeObserver(runtimeErrorObserver)
        self.runtimeErrorObserver = nil
      }
      session.stopRunning()
      continuation.finish()
    }
  }

  /// `sessionQueue` 上でのみ呼ぶ。
  private func configureAndRun() throws {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
    )
    guard let device = discovery.devices.first else { throw ProviderError.noBuiltInCamera }

    session.beginConfiguration()
    if session.canSetSessionPreset(.vga640x480) {
      session.sessionPreset = .vga640x480
    }
    guard let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      session.commitConfiguration()
      throw ProviderError.cannotConfigure
    }
    session.addInput(input)

    // 15fps に絞る（姿勢には十分で、電力を食わない）。対応しない形式なら成り行きに任せる。
    if (try? device.lockForConfiguration()) != nil {
      let frame = CMTime(value: 1, timescale: 15)
      let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
        $0.minFrameDuration <= frame && frame <= $0.maxFrameDuration
      }
      if supported {
        device.activeVideoMinFrameDuration = frame
      }
      device.unlockForConfiguration()
    }

    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: Self.sessionQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw ProviderError.cannotConfigure
    }
    session.addOutput(output)
    session.commitConfiguration()

    // カメラの異常終了（他クライアントに取られた等）はエラー通知でしか分からない。
    // ストリームを終えて、呼び出し側に「止まった」ことを伝える。self は掴まない
    // （NotificationCenter → クロージャ → self の保持環を作らない）。
    runtimeErrorObserver = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
    ) { [continuation] _ in
      continuation.finish()
    }

    session.startRunning()
  }
}

/// deinit から共有キューへセッションだけを運ぶ入れ物。AVCaptureSession は Sendable
/// ではないが、触るのは共有キュー上だけという規律をこの型が名前で示す。
private struct SessionBox: @unchecked Sendable {
  let session: AVCaptureSession
}

extension CameraHeadPoseProvider: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    let imageWidth = Double(CVPixelBufferGetWidth(pixelBuffer))

    let faceRequest = VNDetectFaceRectanglesRequest()
    faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
    try? handler.perform([faceRequest])
    let observations = faceRequest.results ?? []

    guard let index = FaceSelection.index(of: observations.map(\.boundingBox), previous: trackedBox)
    else {
      missCount += 1
      if missCount >= reacquireAfterMisses {
        trackedBox = nil
      }
      continuation.yield(HeadPoseSample(time: time, rotation: nil, pixelIPD: nil, faceWidth: nil))
      return
    }
    missCount = 0
    let face = observations[index]
    trackedBox = face.boundingBox

    // 姿勢角は nullable — 欠けたフレームはロスト扱い（信頼できない値で音場を振らない）。
    let rotation: Rotation?
    if let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue {
      rotation = conversion.rotation(yaw: yaw, pitch: pitch, roll: face.roll?.doubleValue ?? 0)
    } else {
      rotation = nil
    }

    continuation.yield(
      HeadPoseSample(
        time: time,
        rotation: rotation,
        pixelIPD: pupilDistance(of: face, handler: handler, pixelBuffer: pixelBuffer),
        faceWidth: face.boundingBox.width * imageWidth
      )
    )
  }

  /// 選んだ顔1つに絞ってランドマークを掛け、両瞳のピクセル距離を測る。
  /// 矩形検出より重いので全候補には掛けない。
  private func pupilDistance(
    of face: VNFaceObservation,
    handler: VNImageRequestHandler,
    pixelBuffer: CVPixelBuffer
  ) -> Double? {
    let landmarksRequest = VNDetectFaceLandmarksRequest()
    landmarksRequest.inputFaceObservations = [face]
    try? handler.perform([landmarksRequest])
    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    guard let landmarks = landmarksRequest.results?.first?.landmarks,
      let left = landmarks.leftPupil?.pointsInImage(imageSize: size).first,
      let right = landmarks.rightPupil?.pointsInImage(imageSize: size).first
    else { return nil }
    return Double(hypot(left.x - right.x, left.y - right.y))
  }
}
