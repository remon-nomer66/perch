import Foundation
import SpatialAudioKit

/// What `SpatialAudioController` needs from a running capture engine. The app's engine
/// is `MultibandSpatializer`; tests stand in a fake, so the controller's flow is exercised
/// without ever creating a process tap (which would raise the system-audio prompt).
@MainActor
protocol SpatialCaptureEngine: AnyObject {
  /// Blocks with a non-silent sample captured since this engine started. A count that
  /// grew between two looks means audio arrived in between.
  var audibleBlockCount: Int { get }
  /// The system-audio recording grant, asked of the running tap.
  func probeCapturePermission() -> SystemAudioPermission
  /// The tempo heard in the captured audio; nil while no steady beat is found.
  var estimatedBPM: Double? { get }
  func updateListener(_ orientation: ListenerOrientation)
  func setListenerDistance(ratio: Double)
  func stop()
}

/// The switches a new engine is built with.
struct SpatialEngineOptions: Equatable {
  var autoBalance: Bool
  var wander: Bool
  var beat: Bool
}

/// Builds and starts an engine. `onConfigurationChange` fires when the output
/// configuration changes under the running engine.
typealias SpatialEngineFactory = @MainActor (
  _ options: SpatialEngineOptions,
  _ onConfigurationChange: @escaping @Sendable () -> Void
) throws -> any SpatialCaptureEngine

@available(macOS 14.4, *)
extension MultibandSpatializer: SpatialCaptureEngine {
  var estimatedBPM: Double? { movementState.estimatedBPM }
}

enum SpatialEngines {
  /// Core Audio process taps — how the system audio is captured — arrived in macOS 14.4.
  struct Unavailable: Error {}

  /// The app's engine: the multiband spatialiser over a muted global tap.
  @MainActor
  static func makeSpatializer(
    options: SpatialEngineOptions,
    onConfigurationChange: @escaping @Sendable () -> Void
  ) throws -> any SpatialCaptureEngine {
    guard #available(macOS 14.4, *) else { throw Unavailable() }
    // タップは出力デバイスのレートでフレームを届けるので、グラフもそれに合わせて組む。
    // 48kHz 決め打ちだと 44.1kHz の機器（AAC 接続の Bluetooth 等）で全システム音の
    // 速度とピッチが狂う。読めなければ従来通り 48kHz で試み、開始時の照合が実レートを
    // 教えてくれたらそのレートで一度だけ作り直す。
    let preferred = SystemAudioTap.defaultOutputNominalSampleRate() ?? 48_000
    do {
      return try startSpatializer(
        options: options, onConfigurationChange: onConfigurationChange, sampleRate: preferred
      )
    } catch SpatializerStartError.sampleRateMismatch(_, let actual) where actual > 0 {
      return try startSpatializer(
        options: options, onConfigurationChange: onConfigurationChange, sampleRate: actual
      )
    }
  }

  @available(macOS 14.4, *)
  private static func startSpatializer(
    options: SpatialEngineOptions,
    onConfigurationChange: @escaping @Sendable () -> Void,
    sampleRate: Double
  ) throws -> MultibandSpatializer {
    let spatializer = try MultibandSpatializer(
      muteOriginal: true,
      autoBalance: options.autoBalance,
      wanderDegrees: options.wander ? 6 : 0,
      beatDegrees: options.beat ? 5 : 0,
      sampleRate: sampleRate
    )
    spatializer.onConfigurationChange = onConfigurationChange
    try spatializer.start()
    return spatializer
  }
}
