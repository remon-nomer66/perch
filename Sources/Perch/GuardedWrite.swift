/// What a write to a guarded panel field does once its turn in the write chain comes.
///
/// Decided at its turn, not when it was asked: a drag's intermediate value can wait in
/// line while the finger moves on, and by the time it reaches the front a newer value
/// may own the field.
enum GuardedWrite: Equatable {
  /// Overtaken while it waited in line: not sent at all.
  case skip
  /// An intermediate drag value: sent so the listener hears it, not read back. The
  /// field stays guarded — the drag still owns it.
  case send
  /// A settled value: sent, read back, and only then is the guard lifted, so the
  /// periodic refresh never shows the device's lagging value in between.
  case sendAndConfirm

  /// `isCurrent` is whether the write's token is still its field's latest.
  ///
  /// A final always lands, current or not: it ends the drag on the device and carries
  /// the read-back. Dropping an overtaken intermediate is safe only because whatever
  /// overtook it writes the field itself. A newer drag report took the token, and every
  /// report that takes one goes on to its pacer, which writes it once the pointer
  /// pauses, the drag is released, or the quiet spell runs out — nothing is merely
  /// queued behind it, it is scheduled. A tile or a preset that took the field over
  /// queues a write of its own.
  static func step(isFinal: Bool, isCurrent: Bool) -> GuardedWrite {
    if isFinal { return .sendAndConfirm }
    return isCurrent ? .send : .skip
  }

  var sends: Bool { self != .skip }
  var liftsGuard: Bool { self == .sendAndConfirm }
}
