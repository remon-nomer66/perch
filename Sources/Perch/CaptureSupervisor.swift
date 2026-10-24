import SpatialAudioKit

/// Decides, from what the capture is seen doing, whether spatial audio turns on, keeps
/// waiting, rebuilds its tap or gives up. A pure state machine: the controller feeds it
/// one observation per tick and carries out the decision, so the policy is tested as
/// tables, with no process tap involved.
///
/// Turning on: the system-audio recording grant is asked of the tap itself
/// (`SystemAudioPermission`), so a confirmed grant turns on at once — even with nothing
/// playing, which is what lets the switch be on before the music starts. Only when the
/// tap cannot tell does real audio have to prove capture. The original output is muted
/// while the tap runs, so short of a confirmed grant the switch never settles on a silent
/// tap: at the deadline it reverts, and says why.
struct CaptureSupervisor: Equatable {
  struct Timing: Equatable {
    /// How often the capture is looked at while turning on.
    var confirmInterval: Duration = .milliseconds(400)
    /// How long turning on may take. A refusal is not final before this: the first-time
    /// system-audio prompt may still be up, and its answer has to land inside the window.
    var confirmDeadline: Duration = .seconds(6)
  }

  enum Decision: Equatable, Sendable {
    /// Nothing to do yet.
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
  }

  private enum Phase: Equatable {
    /// `sawDenial`: the tap refused at some look of this attempt. `rebuilt`: the one
    /// rebuild this attempt allows has been used.
    case confirming(elapsed: Duration, sawDenial: Bool, rebuilt: Bool)
    case running
  }

  let timing: Timing
  private var phase = Phase.confirming(elapsed: .zero, sawDenial: false, rebuilt: false)

  init(timing: Timing = Timing()) {
    self.timing = timing
  }

  /// Capture was confirmed and the switch is on.
  var isRunning: Bool { phase == .running }

  /// How long until the next look.
  var pollInterval: Duration { timing.confirmInterval }

  /// One look at the capture, `elapsed` after the previous one.
  /// - Parameters:
  ///   - hasSignal: a non-silent block arrived since the previous look.
  ///   - permission: asks the tap for the grant. Called only when the answer matters.
  mutating func observe(
    hasSignal: Bool,
    after elapsed: Duration,
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
    case .running:
      return .hold
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
      phase = .running
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
      phase = .running
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
}
