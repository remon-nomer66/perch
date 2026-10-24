import CoreAudio
import Testing

@testable import SpatialAudioKit

// システムオーディオ録音の許可の判定。手がかりはタップの記述を設定し直した結果だけで、
// 「許可なし」と言えるのは kAudioDevicePermissionsError が返ったときだけ。それ以外の失敗は
// 許可について何も語らないので「判定できない」に倒す（実際の音で確かめる側へ回す）。
// どのテストもプロセスタップは作らない。

@Test(
  "設定し直した結果 → 許可の判定",
  arguments: [
    (noErr, SystemAudioPermission.granted),
    (kAudioDevicePermissionsError, .denied),
    (kAudioHardwareUnknownPropertyError, .unknown),
    (kAudioHardwareBadObjectError, .unknown),
    (kAudioHardwareIllegalOperationError, .unknown),
    (kAudioHardwareUnspecifiedError, .unknown),
    (kAudioHardwareNotRunningError, .unknown),
  ]
)
func probeStatusMapsToPermission(row: (OSStatus, SystemAudioPermission)) {
  let (status, expected) = row
  #expect(SystemAudioPermission(probeStatus: status) == expected)
}

@available(macOS 14.4, *)
@Test("開始前のタップには問い合わせる相手が無い: 判定できない")
func aTapThatHasNotStartedCannotTell() {
  let tap = SystemAudioTap { _ in }
  #expect(tap.probePermission() == .unknown)
}

@available(macOS 14.4, *)
@Test("取り込みを始めていない空間化エンジンも判定できない")
func aSpatializerWithoutCaptureCannotTell() throws {
  let spatializer = try MultibandSpatializer(muteOriginal: false)
  #expect(spatializer.probeCapturePermission() == .unknown)
}
