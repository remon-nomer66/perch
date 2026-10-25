import Foundation
import TandemCore

extension NoiseControlReading {
  /// The reading after an unsolicited noise-control frame, or `nil` when the frame is
  /// not about this reading or changes nothing.
  ///
  /// A setting changed on the device itself — a touch on the headset, or a change made
  /// from the phone app — is announced over the channel as an unsolicited frame, not as
  /// a reply to a request. The periodic read folds such a change in eventually, but only
  /// on its slow keepalive cadence (up to a reading interval later), which is why a
  /// noise-control change made by touch took many seconds to reach the panel. Parsing
  /// the notification updates the reading at once, so the panel reflects a physical
  /// change within a refresh tick.
  ///
  /// Only a noise-control parameter — what a headphone touch actually changes — is
  /// handled; every other unsolicited frame is left untouched for the notification
  /// stream and the gesture log. The reading's shape (modes, field count, wind kind) is
  /// carried over from what was read, since the notification alone does not restate it.
  func applying(unsolicited frame: TandemFrame) -> NoiseControlReading? {
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= 2, bytes[1] == inquiry else { return nil }
    // The device announces a noise-control change with either the return (0x67) or the
    // notify (0x69) command — the same two the write's read-back listens for.
    let announced: TandemNoiseControlState?
    switch bytes[0] {
    case 0x67:
      announced = try? TandemNoiseControlProtocol.parseParameterResponse(frame, inquiry: inquiry)
    case 0x69:
      announced = try? TandemNoiseControlProtocol.parseParameterNotification(frame, inquiry: inquiry)
    default:
      announced = nil
    }
    guard let announced, announced != state else { return nil }
    return NoiseControlReading(
      inquiry: inquiry,
      modes: modes,
      state: announced,
      valueFieldCount: max(bytes.count - 2, valueFieldCount),
      legacyWindKind: inquiry == TandemNoiseControlProtocol.legacyInquiry && bytes.count > 3
        ? bytes[3] : legacyWindKind
    )
  }
}
