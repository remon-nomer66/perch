import CoreAudio

/// システムオーディオ録音の許可（システム設定の「画面収録とシステムオーディオ録音」にある
/// 「システムオーディオ録音のみ」）を、作ったタップ自身に問い合わせた結果。
///
/// この許可を読む公開 API は無い。許可の無いタップもエラーにはならず、無音を届けるだけ。
/// 画面収録の許可（`CGPreflightScreenCaptureAccess`）は別物で、こちらを反映しない。
/// 確かめる手段として報告されているのが、タップの `kAudioTapPropertyDescription` を同じ記述で
/// 設定し直すこと: 許可が無ければ `kAudioDevicePermissionsError` が返る（Apple の文書には
/// 無い、開発者フォーラムでの報告に基づく挙動）。それ以外の失敗は許可の有無を語らないので
/// 「判定できない」として扱い、実際の音で確かめる側へ回す。
public enum SystemAudioPermission: Sendable, Equatable {
  case granted
  case denied
  /// 問い合わせる相手（取り込み中のタップ）が無い、または許可と関係のない失敗。
  case unknown

  /// タップの記述を設定し直した結果から判定する。
  public init(probeStatus: OSStatus) {
    switch probeStatus {
    case noErr: self = .granted
    case kAudioDevicePermissionsError: self = .denied
    default: self = .unknown
    }
  }
}
