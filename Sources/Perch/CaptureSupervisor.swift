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
/// while another process is playing (or may be: unreadable counts as playing) may mean
/// capture was lost — the grant revoked, a tap gone deaf — and with the original muted
/// the whole Mac would be silent. The tap is rebuilt once. If the fresh tap still hears
/// nothing, it is asked for the grant: a refusal, or no answer, gives up and says why.
/// A fresh tap that is allowed to record and still hears silence means the silence is
/// the other app's own — browsers keep WebAudio output running while quiet, calls sit
/// silent between speakers — so spatial audio stays on, asking the tap again once per
/// timeout in case the grant goes. But only once real audio has been heard since
/// turning on: the tap's "allowed" is itself an unproven answer, so on its own it never
/// keeps a silent Mac — wrong answers, or a tap that is allowed but cannot capture,
/// still give the sound back. And not for ever: the vouch lapses once the tap has been
/// silent for `vouchLimit` while others play, counted from the last real audio.
///
/// The other half of a running feature is the spatialised output. When it stops for
/// longer than a configuration change takes to be rebuilt, the original is still muted
/// and nothing replaces it: it is rebuilt once, and given up on if it stops again.
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
    /// How long nothing else must play before a stretch of silence, and what was done
    /// about it, is forgotten.
    var quietReset: Duration = .seconds(3)
    /// How long the spatialised output may be stopped before the watch steps in. A
    /// configuration change stops it too, and its own handler rebuilds within a moment.
    var outputGrace: Duration = .seconds(2)
    /// How long either question to coreaudiod may take before it counts as unanswered.
    var questionTimeout: Duration = .milliseconds(500)
    /// How long a vouched tap may stay silent while others play, counted from the last
    /// real audio, before the vouch lapses.
    ///
    /// The trade-off, chosen on purpose: a paused browser tab that keeps its output open
    /// in silence turns spatial audio off after this long (never within seconds); in
    /// exchange, if the tap's "allowed" was wrong — or the tap went deaf after the audio
    /// that vouched for it — the original stays muted for at most this long.
    var vouchLimit: Duration = .seconds(180)
    /// How many looks a decision that is due may wait for the tap's answer when the
    /// question went unanswered (timed out, or an earlier one is still out) — which is
    /// not the tap answering that it cannot tell, and must not decide like it.
    var answerDeferrals = 3

    /// The longest gap between two looks that still counts as time watched: the interval
    /// overrun by both questions, with slack. Anything longer — the Mac slept, the main
    /// actor stalled — says nothing about the capture, and would expire every timer at
    /// once (the clock keeps running through sleep).
    func longestCountedStep(after interval: Duration) -> Duration {
      interval * 2 + questionTimeout
    }
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
    /// The spatialised output stopped, and stopped again after a rebuild.
    case outputStopped
  }

  private enum Phase: Equatable {
    case confirming(Confirmation)
    case running(Watch)
  }

  /// Turning on, so far.
  private struct Confirmation: Equatable {
    var elapsed: Duration = .zero
    /// The tap refused at some look of this attempt — what the deadline reports.
    var sawDenial = false
    /// The tap gave anything but "allowed" at some look: a later "allowed" means the
    /// grant landed while this tap was live.
    var sawNonGrant = false
    /// The one rebuild this attempt allows has been used.
    var rebuilt = false
    /// Looks the due decision has waited for an answer.
    var deferred = 0
  }

  /// Watching a running capture, so far.
  private struct Watch: Equatable {
    /// Real audio has arrived at least once since turning on — the only proof that
    /// capture works, which an answer from the tap is not.
    var heardSignal: Bool
    /// How long the tap has been silent while another process may be playing.
    var silent: Duration = .zero
    /// How long nothing else has been playing, without audio either.
    var quiet: Duration = .zero
    /// How long the tap has been silent while others may be playing, since the last real
    /// audio. Only real audio resets it — a pause in the others' playing only stops it
    /// counting.
    var unheard: Duration = .zero
    var recovery = Recovery.none
    /// Looks a due decision has waited for the tap's answer.
    var deferred = 0
    var output = OutputWatch()
  }

  /// The spatialised output, watched apart from the capture: audio arriving says
  /// nothing about whether it is being played back.
  private struct OutputWatch: Equatable {
    /// How long the output has been found stopped.
    var down: Duration = .zero
    /// How long it has run since the rebuild it cost.
    var up: Duration = .zero
    /// A rebuild has been spent on it, and it has not yet run long enough to earn
    /// another.
    var rebuilt = false
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
  private var phase = Phase.confirming(Confirmation())

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

  /// One look at the capture, `elapsed` after the previous one — the time that really
  /// passed, questions included, not the nominal interval. A gap far longer than a look
  /// can take (sleep, a stalled main actor) is not counted: the look is still made, but
  /// no timer moves.
  /// - Parameters:
  ///   - hasSignal: a non-silent block arrived since the previous look.
  ///   - outputRunning: the spatialised output is playing. Watched once on.
  ///   - othersPlaying: whether a process other than Perch is outputting audio; nil when
  ///     that cannot be read. Asked only when the answer matters.
  ///   - permission: asks the tap for the grant; nil when no answer came in time. Asked
  ///     only when the answer matters.
  ///
  /// The questions are round trips to coreaudiod that the caller runs elsewhere; the
  /// decision itself is pure, and runs wherever it is called from.
  nonisolated(nonsending) mutating func observe(
    hasSignal: Bool,
    outputRunning: Bool,
    after elapsed: Duration,
    othersPlaying: () async -> Bool?,
    permission: () async -> SystemAudioPermission?
  ) async -> Decision {
    let counted = elapsed <= timing.longestCountedStep(after: pollInterval) ? elapsed : .zero
    switch phase {
    case .confirming(var confirmation):
      confirmation.elapsed += counted
      return await confirm(hasSignal: hasSignal, confirmation, permission: permission)
    case .running(let watch):
      return await self.watch(
        hasSignal: hasSignal,
        outputRunning: outputRunning,
        elapsed: counted,
        watch,
        othersPlaying: othersPlaying,
        permission: permission
      )
    }
  }

  private nonisolated(nonsending) mutating func confirm(
    hasSignal: Bool,
    _ confirmation: Confirmation,
    permission: () async -> SystemAudioPermission?
  ) async -> Decision {
    // Real audio is proof whatever the tap says about the grant.
    if hasSignal {
      phase = .running(Watch(heardSignal: true))
      return .commit
    }
    var next = confirmation
    let answer = await permission()
    let due = next.elapsed >= timing.confirmDeadline
    switch answer {
    case .granted? where confirmation.sawNonGrant && !confirmation.rebuilt:
      // The grant landed while this tap was live (it said no, could not tell, or did not
      // answer before), and a tap built before the grant can stay silent. A fresh one,
      // with a full window of its own.
      phase = .confirming(Confirmation(rebuilt: true))
      return .rebuild
    case .granted?:
      phase = .running(Watch(heardSignal: false))
      return .commit
    case nil where due && next.deferred < timing.answerDeferrals:
      // The decision is due, but the question went unanswered: wait a look for the answer
      // rather than decide on the lack of one.
      next.deferred += 1
      next.sawNonGrant = true
      phase = .confirming(next)
      return .hold
    case .denied?, .unknown?, nil:
      next.sawDenial = next.sawDenial || answer == .denied
      next.sawNonGrant = true
      guard next.elapsed >= timing.confirmDeadline else {
        phase = .confirming(next)
        return .hold
      }
      return .revoke(next.sawDenial ? .permissionDenied : .noAudioDetected)
    }
  }

  private nonisolated(nonsending) mutating func watch(
    hasSignal: Bool,
    outputRunning: Bool,
    elapsed: Duration,
    _ watch: Watch,
    othersPlaying: () async -> Bool?,
    permission: () async -> SystemAudioPermission?
  ) async -> Decision {
    var next = watch
    next.heardSignal = watch.heardSignal || hasSignal
    guard outputRunning else {
      next.output.up = .zero
      next.output.down += elapsed
      guard next.output.down >= timing.outputGrace else { return keepWatching(next) }
      // The spatialised copy is gone while the original stays muted.
      if watch.output.rebuilt { return .revoke(.outputStopped) }
      next.output = OutputWatch(rebuilt: true)
      phase = .running(next)
      return .rebuild
    }
    next.output.down = .zero
    if next.output.rebuilt {
      next.output.up += elapsed
      if next.output.up >= timing.stallTimeout { next.output = OutputWatch() }
    }
    if hasSignal {
      // Audio flows: the capture is fine, and a later silence is a new stretch with a
      // rebuild of its own.
      phase = .running(Watch(heardSignal: true, output: next.output))
      return .hold
    }
    // Unreadable counts as "may be playing": that is the side where a muted Mac gets
    // its sound back.
    guard await othersPlaying() != false else {
      // Nothing else is playing: silence is what there is to hear. Only once that has
      // lasted is the stretch forgotten — one quiet look between two silent ones must
      // not throw away a vouched tap and cost another rebuild.
      next.quiet += elapsed
      if next.quiet >= timing.quietReset {
        next = Watch(heardSignal: next.heardSignal, unheard: next.unheard, output: next.output)
      }
      return keepWatching(next)
    }
    next.quiet = .zero
    next.silent += elapsed
    next.unheard += elapsed
    let timedOut = next.silent >= timing.stallTimeout
    switch watch.recovery {
    case .none:
      guard timedOut else { return keepWatching(next) }
      next.silent = .zero
      next.recovery = .rebuilt
      phase = .running(next)
      return .rebuild
    case .rebuilt:
      // The whole Mac is muted meanwhile: a refusal from the fresh tap ends it at once.
      let answer = await permission()
      if answer == .denied { return .revoke(.permissionDenied) }
      guard timedOut else { return keepWatching(next) }
      if answer == nil, next.deferred < timing.answerDeferrals {
        // Due, but unanswered: a healthy tap must not be given up on for a slow reply.
        next.deferred += 1
        return keepWatching(next)
      }
      // "Allowed" is only believed once real audio has borne capture out. Without that,
      // a wrong answer — or a tap that may record but cannot — would keep the original
      // muted for good.
      guard answer == .granted, next.heardSignal else { return .revoke(.captureLost) }
      next.silent = .zero
      next.deferred = 0
      next.recovery = .vouched
      return keepWatching(next)
    case .vouched:
      // The vouch rests on audio heard before; it does not outlast this much silence.
      if next.unheard >= timing.vouchLimit { return .revoke(.captureLost) }
      guard timedOut else { return keepWatching(next) }
      switch await permission() {
      case .granted?:
        next.silent = .zero
        next.deferred = 0
        return keepWatching(next)
      case .denied?:
        return .revoke(.permissionDenied)
      case nil where next.deferred < timing.answerDeferrals:
        next.deferred += 1
        return keepWatching(next)
      case .unknown?, nil:
        return .revoke(.captureLost)
      }
    }
  }

  private mutating func keepWatching(_ watch: Watch) -> Decision {
    phase = .running(watch)
    return .hold
  }
}
