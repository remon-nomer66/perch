import AudioToolbox
import CoreAudio
import Foundation
import os

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
    /// 自プロセスの除外が必須なのに、自分のプロセスオブジェクトを特定できなかった。
    case resolveCurrentProcessFailed
  }

  /// 取得した1ブロックぶんの音声。オーディオスレッドから呼ばれる。
  public typealias AudioHandler = @Sendable (UnsafePointer<AudioBufferList>) -> Void

  private let handler: AudioHandler
  private let muteOriginal: Bool
  private let excludeCurrentProcess: Bool
  private let queue = DispatchQueue(label: "app.perch.spatial.systemtap", qos: .userInteractive)
  private static let log = Logger(subsystem: "dev.perch.mac", category: "spatial")

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  /// タップを作った記述。許可の問い合わせで、同じものを設定し直すために持っておく。
  private var tapDescription: CATapDescription?
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var running = false

  /// 取得音声のフォーマット（`start()` 成功後に有効）。
  public private(set) var streamFormat = AudioStreamBasicDescription()

  /// - Parameters:
  ///   - muteOriginal: 原音を出力経路から消すか（空間化版を代わりに流すときは true）。
  ///   - excludeCurrentProcess: 自プロセスをタップ対象から除く（自分の出力を取り込む
  ///     フィードバックを防ぐ。空間化して出力するときは true）。
  public init(
    muteOriginal: Bool = false,
    excludeCurrentProcess: Bool = false,
    handler: @escaping AudioHandler
  ) {
    self.muteOriginal = muteOriginal
    self.excludeCurrentProcess = excludeCurrentProcess
    self.handler = handler
  }

  public func start() throws {
    // 1. タップ記述。システム全体を取得（必要なら自プロセスを除外）。
    // 除外が必須の構成（空間化した音を自分で再生する）で自分を特定できないまま
    // 進むと、自分の出力を再取得するフィードバックループになる。開始しない。
    var excluded: [AudioObjectID] = []
    if excludeCurrentProcess {
      guard let ownObject = Self.currentProcessObjectID() else {
        throw TapError.resolveCurrentProcessFailed
      }
      excluded = [ownObject]
    }
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
    description.isPrivate = true
    description.muteBehavior = muteOriginal ? .muted : .unmuted

    var newTap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
    guard tapStatus == noErr else { throw TapError.createTapFailed(tapStatus) }
    tapID = newTap
    tapDescription = description

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

  /// システムオーディオ録音の許可を、このタップに問い合わせる手立て（`start()` の後で
  /// 有効。タップが無ければ nil）。
  ///
  /// 問い合わせは coreaudiod との同期の往復なので、呼び出し側がメインスレッドの外で
  /// `run()` すること。持つのは値だけで、どのスレッドからでも走らせられる。
  public var permissionProbe: PermissionProbe? {
    guard tapID != AudioObjectID(kAudioObjectUnknown), let tapDescription else { return nil }
    return PermissionProbe(tapID: tapID, tapDescription: tapDescription)
  }

  /// `permissionProbe` をその場で走らせる。呼んだスレッドを往復の間ふさぐ。
  public func probePermission() -> SystemAudioPermission {
    permissionProbe?.run() ?? .unknown
  }

  /// 作ったときと同じ記述を `kAudioTapPropertyDescription` へ設定し直し、返ってきた結果で
  /// 許可を判定する（`SystemAudioPermission` を参照）。記述は変わらないので、取り込みは
  /// 続く。タップが先に片付けられていれば、Core Audio が不正なオブジェクトとして断る
  /// だけで、判定できないになる。
  ///
  /// `CATapDescription` は Sendable ではないが、タップを作った後は誰も書き換えず、ここでは
  /// Core Audio へ渡すだけなので、スレッドをまたいで持ち運んでよい。
  public struct PermissionProbe: @unchecked Sendable {
    fileprivate let tapID: AudioObjectID
    fileprivate let tapDescription: CATapDescription

    public func run() -> SystemAudioPermission {
      var description = tapDescription
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let size = UInt32(MemoryLayout<CATapDescription>.stride)
      let status = withUnsafeMutablePointer(to: &description) { pointer in
        AudioObjectSetPropertyData(tapID, &address, 0, nil, size, pointer)
      }
      let permission = SystemAudioPermission(probeStatus: status)
      if permission == .unknown {
        // 許可と関係のない失敗。後から原因を追えるよう、生の値を残す。
        SystemAudioTap.log.notice(
          "tap permission probe inconclusive: status \(status, privacy: .public)"
        )
      }
      return permission
    }
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
    tapDescription = nil
    running = false
  }

  deinit {
    cleanUp()
  }

  /// 既定出力デバイスの公称サンプルレート。タップはこのレートでフレームを届けるので、
  /// 空間化グラフをこれに合わせて組むために読む。読めなければ nil。
  public static func defaultOutputNominalSampleRate() -> Double? {
    var deviceAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(kAudioObjectUnknown)
    var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let deviceStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device
    )
    guard deviceStatus == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }

    var rateAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate = Float64(0)
    var rateSize = UInt32(MemoryLayout<Float64>.size)
    let rateStatus = AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate)
    guard rateStatus == noErr, rate > 0 else { return nil }
    return rate
  }

  /// 自プロセスの pid を Core Audio のプロセスオブジェクトIDへ変換する。
  /// タップから自分の出力を除外するために使う。他のプロセスの一覧から自分を見分ける
  /// ときも、同じ ID で比べる。
  public static func currentProcessObjectID() -> AudioObjectID? {
    var pid = getpid()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &pid) { pidPointer -> OSStatus in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        pidPointer,
        &size,
        &objectID
      )
    }
    return status == noErr && objectID != AudioObjectID(kAudioObjectUnknown) ? objectID : nil
  }
}
