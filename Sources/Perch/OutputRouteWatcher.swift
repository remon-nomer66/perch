import CoreAudio
import Foundation

/// いまの既定出力がヘッドホン/イヤホンかどうかを見張る。
///
/// 空間オーディオは HRTF バイノーラル — 両耳に独立した音を届けるヘッドホンが前提で、
/// スピーカーで鳴らすと定位が崩れて「微妙」になる。そこで:
/// - ヘッドホン以外が既定出力の間は、空間オーディオをオンにさせない
/// - 使用中にヘッドホンが外れたら（既定出力がスピーカーへ切り替わったら）自動でオフ
///   （ヘッドトラッキングのカメラも連鎖して止まる）
///
/// 判定は**スピーカーと分かっているものだけを弾く**方向に倒す: 内蔵スピーカー・
/// HDMI/DisplayPort・AirPlay・内蔵バスのライン出力は不可、Bluetooth（Sony 機の経路）・
/// 内蔵ジャックのヘッドホン・USB/Thunderbolt の DAC 等は可。USB スピーカーまで区別する
/// 手段は Core Audio に無いので、疑わしきは使わせる（ユーザーの耳がすぐ気づく）。
@MainActor
final class OutputRouteWatcher: ObservableObject {
  @Published private(set) var isHeadphones = false

  private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
  private let listenerQueue = DispatchQueue.main

  /// 既定出力の変化（付け外し・切り替え）で判定し直す。データソースの変化
  /// （内蔵ジャックの抜き差しはデバイスが変わらずソースだけ変わる）も同様。
  private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    Task { @MainActor [weak self] in
      self?.refresh()
    }
  }

  init() {
    var address = Self.defaultOutputAddress
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
    )
    refresh()
  }

  private func refresh() {
    let device = Self.defaultOutputDevice()
    if device != watchedDevice {
      moveDataSourceListener(to: device)
    }
    guard device != kAudioObjectUnknown else {
      isHeadphones = false
      return
    }
    let headphones = Self.isHeadphones(
      transportType: Self.transportType(of: device),
      dataSource: Self.dataSource(of: device)
    )
    if headphones != isHeadphones {
      isHeadphones = headphones
    }
  }

  /// 内蔵ジャックの抜き差しはデバイス ID が変わらない（データソースが 'ispk'↔'hdpn'
  /// で切り替わるだけ）ので、いまの既定デバイスのデータソースにも耳を立てる。
  private func moveDataSourceListener(to device: AudioObjectID) {
    var address = Self.dataSourceAddress
    if watchedDevice != kAudioObjectUnknown {
      AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, listenerQueue, listener)
    }
    watchedDevice = device
    if device != kAudioObjectUnknown {
      AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, listener)
    }
  }

  // MARK: - 判定（純粋・テスト可能）

  /// スピーカーと分かっている経路だけを false にする。
  nonisolated static func isHeadphones(transportType: UInt32, dataSource: UInt32?) -> Bool {
    switch transportType {
    case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE):
      return true
    case UInt32(kAudioDeviceTransportTypeBuiltIn):
      // 内蔵はデータソースで見分ける: 'hdpn' = ヘッドホンジャック、'ispk' = 内蔵スピーカー。
      return dataSource == fourCharCode("hdpn")
    case UInt32(kAudioDeviceTransportTypeHDMI),
      UInt32(kAudioDeviceTransportTypeDisplayPort),
      UInt32(kAudioDeviceTransportTypeAirPlay):
      return false
    default:
      // USB/Thunderbolt DAC・仮想デバイス等: スピーカーとは断定できないので通す。
      return true
    }
  }

  nonisolated static func fourCharCode(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  // MARK: - Core Audio 呼び出し

  private static var defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  private static var dataSourceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDataSource,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
  )

  private static func defaultOutputDevice() -> AudioObjectID {
    var address = defaultOutputAddress
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
    )
    return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
  }

  private static func transportType(of device: AudioObjectID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
    return status == noErr ? transport : 0
  }

  private static func dataSource(of device: AudioObjectID) -> UInt32? {
    var address = dataSourceAddress
    var source: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)
    return status == noErr ? source : nil
  }
}
