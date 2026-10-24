import SpatialAudioKit

/// Decides, from what the capture is seen doing, whether spatial audio turns on, keeps
/// going, rebuilds its tap or gives up. A pure state machine: the controller feeds it
/// one observation per tick and carries out the decision, so the policy is tested as
/// tables, with no process tap involved.
///
/// Turning on: the system-audio recording grant is asked of the tap itself
/// (`SystemAudioPermission`), so a confirmed grant turns on at once — even with nothing
/// playing, which is what lets the switch be on before the music starts. Only when the
/// tap cannot tell does real audio have to prove capture. The original output is muted
/// while the tap runs, so short of a confirmed grant the switch never settles on a silent
/// tap: at the deadline it reverts, and says why.
///
/// Running: silence while nothing else plays is simply what there is to hear. Silence
/// while another process is playing may mean capture was lost — the grant revoked, a
/// tap gone deaf — and with the original muted the whole Mac would be silent. The tap is
/// rebuilt once. If the fresh tap still hears nothing, it is asked for the grant: a
/// refusal, or no answer, gives up and says why. A fresh tap that is allowed to record
/// and still hears silence means the silence is the other app's own — browsers keep
/// WebAudio output running while quiet, calls sit silent between speakers — so spatial
/// audio stays on, asking the tap again once per timeout in case the grant goes. But
/// only once real audio has been heard since turning on: the tap's "allowed" is itself
/// an unproven answer, so on its own it never keeps a silent Mac — wrong answers, or a
/// tap that is allowed but cannot capture, still give the sound back.
struct CaptureSupervisor: Equatable {
  struct Timing: Equatable {
    /// How often the capture is looked at while turning on.
    var confirmInterval: Duration = .milliseconds(400)
    /// How long turning on may take. A refusal is not final before this: the first-time
    /// system-audio prompt may still be up, and its answer has to land inside the window.
    var confirmDeadline: Duration = .seconds(6)
    /// How often the capture is looked at while on.
    var watchInterval: Duration = .seconds(1)
    /// How long the tap may stay silent while another process plays before something is
    /// done about it. Long enough to ride out the gap between tracks.
    var stallTimeout: Duration = .seconds(5)
  }

  enum Decision: Equatable, Sendable {
    /// Nothing to do.
    case hold
    /// Capture is confirmed: the switch turns on.
    case commit
    /// Replace the tap with a fresh one, then keep watching.
    case rebuild
    /// Give up: tear down and tell the user why.
    case revoke(Revocation)
  }

  enum Revocation: Equatable, Sendable {
    /// The tap said system audio recording is not allowed.
    case permissionDenied
    /// The grant could not be read and no audio arrived — most likely nothing was playing.
    case noAudioDetected
    /// While on, the tap went silent with another process playing and a rebuild did not
    /// bring the audio back — and neither the tap's answer nor audio heard earlier
    /// vouches for the capture.
    case captureLost
  }

  private enum Phase: Equatable {
    /// `sawDenial`: the tap refused at some look of this attempt. `rebuilt`: the one
    /// rebuild this attempt allows has been used.
    case confirming(elapsed: Duration, sawDenial: Bool, rebuilt: Bool)
    /// `silent`: how long the tap has been silent while another process plays.
    /// `heardSignal`: real audio has arrived at least once since turning on — the only
    /// proof that capture works, which an answer from the tap is not.
    case running(silent: Duration, recovery: Recovery, heardSignal: Bool)
  }

  /// How far one stretch of silence-while-others-play has been handled.
  private enum Recovery: Equatable {
    /// Nothing done yet.
    case none
    /// The tap was rebuilt; the fresh one is asked for the grant at every look.
    case rebuilt
    /// The fresh tap may record, so the silence is the other app's own.
    case vouched
  }

  let timing: Timing
  private var phase = Phase.confirming(elapsed: .zero, sawDenial: false, rebuilt: false)

  init(timing: Timing = Timing()) {
    self.timing = timing
  }

  /// Capture was confirmed and the switch is on.
  var isRunning: Bool {
    if case .running = phase { return true }
    return false
  }

  /// How long until the next look.
  var pollInterval: Duration {
    isRunning ? timing.watchInterval : timing.confirmInterval
  }

  /// One look at the capture, `elapsed` after the previous one.
  /// - Parameters:
  ///   - hasSignal: a non-silent block arrived since the previous look.
  ///   - othersPlaying: whether a process other than Perch is outputting audio; nil when
  ///     that cannot be read. Called only when the answer matters.
  ///   - permission: asks the tap for the grant. Called only when the answer matters.
  mutating func observe(
    hasSignal: Bool,
    after elapsed: Duration,
    othersPlaying: () -> Bool?,
    permission: () -> SystemAudioPermission
  ) -> Decision {
    switch phase {
    case let .confirming(previous, sawDenial, rebuilt):
      return confirm(
        hasSignal: hasSignal,
        elapsed: previous + elapsed,
        sawDenial: sawDenial,
        rebuilt: rebuilt,
        permission: permission
      )
    case let .running(silent, recovery, heardSignal):
      return watch(
        hasSignal: hasSignal,
        silentFor: silent + elapsed,
        recovery: recovery,
        heardSignal: heardSignal,
        othersPlaying: othersPlaying,
        permission: permission
      )
    }
  }

  private mutating func confirm(
    hasSignal: Bool,
    elapsed: Duration,
    sawDenial: Bool,
    rebuilt: Bool,
    permission: () -> SystemAudioPermission
  ) -> Decision {
    // Real audio is proof whatever the tap says about the grant.
    if hasSignal {
      phase = .running(silent: .zero, recovery: .none, heardSignal: true)
      return .commit
    }
    let answer = permission()
    switch answer {
    case .granted where sawDenial && !rebuilt:
      // The grant landed while this tap was live, and a tap built before the grant can
      // stay silent. A fresh one, with a full window of its own.
      phase = .confirming(elapsed: .zero, sawDenial: false, rebuilt: true)
      return .rebuild
    case .granted:
      phase = .running(silent: .zero, recovery: .none, heardSignal: false)
      return .commit
    case .denied, .unknown:
      let refused = sawDenial || answer == .denied
      guard elapsed >= timing.confirmDeadline else {
        phase = .confirming(elapsed: elapsed, sawDenial: refused, rebuilt: rebuilt)
        return .hold
      }
      return .revoke(refused ? .permissionDenied : .noAudioDetected)
    }
  }

  private mutating func watch(
    hasSignal: Bool,
    silentFor: Duration,
    recovery: Recovery,
    heardSignal: Bool,
    othersPlaying: () -> Bool?,
    permission: () -> SystemAudioPermission
  ) -> Decision {
    let heard = heardSignal || hasSignal
    guard !hasSignal, othersPlaying() == true else {
      // Audio flows, or nothing else is playing (or that cannot be read) — silence is
      // then what there is to hear. Either way the capture is fine, and a later silence
      // is a new stretch with a rebuild of its own.
      phase = .running(silent: .zero, recovery: .none, heardSignal: heard)
      return .hold
    }
    let timedOut = silentFor >= timing.stallTimeout
    switch recovery {
    case .none:
      guard timedOut else { return keepWatching(silentFor, .none, heard) }
      phase = .running(silent: .zero, recovery: .rebuilt, heardSignal: heard)
      return .rebuild
    case .rebuilt:
      // The whole Mac is muted meanwhile: a refusal from the fresh tap ends it at once.
      let answer = permission()
      if answer == .denied { return .revoke(.permissionDenied) }
      guard timedOut else { return keepWatching(silentFor, .rebuilt, heard) }
      // "Allowed" is only believed once real audio has borne capture out. Without that,
      // a wrong answer — or a tap that may record but cannot — would keep the original
      // muted for good.
      guard answer == .granted, heard else { return .revoke(.captureLost) }
      return keepWatching(.zero, .vouched, heard)
    case .vouched:
      guard timedOut else { return keepWatching(silentFor, .vouched, heard) }
      switch permission() {
      case .granted: return keepWatching(.zero, .vouched, heard)
      case .denied: return .revoke(.permissionDenied)
      case .unknown: return .revoke(.captureLost)
      }
    }
  }

  private mutating func keepWatching(
    _ silent: Duration, _ recovery: Recovery, _ heardSignal: Bool
  ) -> Decision {
    phase = .running(silent: silent, recovery: recovery, heardSignal: heardSignal)
    return .hold
  }
}
