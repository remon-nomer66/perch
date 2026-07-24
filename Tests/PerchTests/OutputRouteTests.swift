import CoreAudio
import Testing

@testable import Perch

// 出力先の判定の約束: スピーカーと分かっているものだけを弾き、疑わしきは通す。

@Test("Bluetooth はヘッドホン扱い（Sony 機の経路）")
func bluetoothIsHeadphones() {
  #expect(OutputRouteWatcher.isHeadphones(
    transportType: UInt32(kAudioDeviceTransportTypeBluetooth), dataSource: nil
  ))
  #expect(OutputRouteWatcher.isHeadphones(
    transportType: UInt32(kAudioDeviceTransportTypeBluetoothLE), dataSource: nil
  ))
}

@Test("内蔵はデータソースで見分ける: ジャックのヘッドホンは可、内蔵スピーカーは不可")
func builtInFollowsTheDataSource() {
  let builtIn = UInt32(kAudioDeviceTransportTypeBuiltIn)
  #expect(OutputRouteWatcher.isHeadphones(
    transportType: builtIn, dataSource: OutputRouteWatcher.fourCharCode("hdpn")
  ))
  #expect(!OutputRouteWatcher.isHeadphones(
    transportType: builtIn, dataSource: OutputRouteWatcher.fourCharCode("ispk")
  ))
  #expect(!OutputRouteWatcher.isHeadphones(transportType: builtIn, dataSource: nil))
}

@Test("HDMI / DisplayPort / AirPlay はスピーカー側として弾く")
func externalDisplaysAreSpeakers() {
  for transport in [
    UInt32(kAudioDeviceTransportTypeHDMI),
    UInt32(kAudioDeviceTransportTypeDisplayPort),
    UInt32(kAudioDeviceTransportTypeAirPlay),
  ] {
    #expect(!OutputRouteWatcher.isHeadphones(transportType: transport, dataSource: nil))
  }
}

@Test("USB 等の断定できない経路は通す（DAC + ヘッドホンを弾かない）")
func ambiguousRoutesPass() {
  #expect(OutputRouteWatcher.isHeadphones(
    transportType: UInt32(kAudioDeviceTransportTypeUSB), dataSource: nil
  ))
}
