import AudioToolbox
import CoreAudio
import Foundation

/// システム音声を Core Audio プロセスタップで横取りする（macOS 14.4+）。
///
/// 「ミュートしないグローバルタップ ＋ タップを含む private aggregate device ＋
/// IOProc」という、仮想ドライバ不要の構成（AudioCap / OnlyEQ で実証済みの手順）。
/// 取得したフレームは `handler` に渡す。発音・権限は実機でのみ確認でき、この段階では
/// コンパイル検証まで。実運用では署名 + `NSAudioCaptureUsageDescription` が要る。
///
/// この capture-only 版は原音をミュートしない（ユーザは音を聞き続けられる）。空間化と
/// つなぐ段階で、原音のミュートと自プロセス除外を加える。
@available(macOS 14.4, *)
public final class SystemAudioTap {
  public enum TapError: Error, Equatable {
    case createTapFailed(OSStatus)
    case readFormatFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startFailed(OSStatus)
  }

  /// 取得した1ブロックぶんの音声。オーディオスレッドから呼ばれる。
  public typealias AudioHandler = @Sendable (UnsafePointer<AudioBufferList>) -> Void

  private let handler: AudioHandler
  private let queue = DispatchQueue(label: "app.perch.spatial.systemtap", qos: .userInteractive)

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var running = false

  /// 取得音声のフォーマット（`start()` 成功後に有効）。
  public private(set) var streamFormat = AudioStreamBasicDescription()

  public init(handler: @escaping AudioHandler) {
    self.handler = handler
  }

  public func start() throws {
    // 1. タップ記述。システム全体を取得（除外プロセスなし）、原音はミュートしない。
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var newTap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
    guard tapStatus == noErr else { throw TapError.createTapFailed(tapStatus) }
    tapID = newTap

    // 2. タップのストリームフォーマットを読む（Float の解釈に必要）。
    var formatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatStatus = AudioObjectGetPropertyData(
      tapID, &formatAddress, 0, nil, &formatSize, &streamFormat
    )
    guard formatStatus == noErr else {
      cleanUp()
      throw TapError.readFormatFailed(formatStatus)
    }

    // 3. タップを含む private aggregate device を作る。
    let aggregateUID = UUID().uuidString
    let tapUID = description.uuid.uuidString
    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "PerchSpatialCapture",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: true,
        ]
      ],
    ]
    var newAggregate = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(
      aggregateDescription as CFDictionary, &newAggregate
    )
    guard aggregateStatus == noErr else {
      cleanUp()
      throw TapError.createAggregateFailed(aggregateStatus)
    }
    aggregateID = newAggregate

    // 4. IOProc。オーディオスレッドから handler を呼ぶ。self を捕まえないよう
    //    handler をローカルに束ねてから渡す（並行性・実時間安全のため）。
    let capturedHandler = handler
    var newProcID: AudioDeviceIOProcID?
    let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
      &newProcID, aggregateID, queue
    ) { _, inInputData, _, _, _ in
      capturedHandler(inInputData)
    }
    guard ioStatus == noErr, let procID = newProcID else {
      cleanUp()
      throw TapError.createIOProcFailed(ioStatus)
    }
    ioProcID = procID

    // 5. 開始。
    let startStatus = AudioDeviceStart(aggregateID, procID)
    guard startStatus == noErr else {
      cleanUp()
      throw TapError.startFailed(startStatus)
    }
    running = true
  }

  public func stop() {
    cleanUp()
  }

  private func cleanUp() {
    if running, let procID = ioProcID {
      AudioDeviceStop(aggregateID, procID)
    }
    if let procID = ioProcID {
      AudioDeviceDestroyIOProcID(aggregateID, procID)
      ioProcID = nil
    }
    if aggregateID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    running = false
  }

  deinit {
    cleanUp()
  }
}
