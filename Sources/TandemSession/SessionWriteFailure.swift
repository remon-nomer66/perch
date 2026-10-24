import Foundation
import TandemCore

extension SessionCoordinator {
  public enum WriteFailure: Error, Equatable, Sendable {
    case notPermitted
    case unsupported
    /// The device answered, but with something other than what was asked for. The
    /// value in hand is what it actually holds.
    case notApplied(TandemNoiseControlState)
    case notAppliedListening(TandemListeningSelection)
    /// The equaliser read-back did not hold the requested preset or bands. The values
    /// carried are what the device actually holds.
    case notAppliedEqualizer(selectedPreset: UInt8?, bandSteps: [Int])
    /// The speak-to-chat read-back did not hold the requested values.
    case notAppliedSpeakToChat(SpeakToChatReading)
    /// The sidetone read-back did not hold the requested value. What is carried is
    /// what the device actually holds.
    case notAppliedSidetone(SidetoneReading)
    case failed(SessionRequestFailure)
  }
}
