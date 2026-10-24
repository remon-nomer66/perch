import Foundation
import TandemCore

extension SessionCoordinator {
  /// Everything a panel refresh needs, read in one actor hop so the fields are always
  /// of the same instant. Taken one accessor at a time, an `invalidate()` could land
  /// between them and hand the panel a `.ready` phase with a nil fingerprint for a
  /// frame; with device-scoped rules that momentary nil model name unmatched a rule and
  /// set noise/EQ flapping. A single hop cannot be interrupted.
  public struct Snapshot: Sendable {
    public let phase: SessionState.Phase
    public let fingerprint: TandemDeviceFingerprint?
    public let unsupportedReason: TandemDeviceVerificationFailure?
    public let acceptsWrites: Bool
    public let readings: DeviceReadings
  }
}
