import Foundation

public enum Freshness: Equatable, Sendable {
  /// Never read from this device.
  case unknown
  /// Read or notified during the current session.
  case fresh
  /// Read at some point, but no longer in sync.
  case stale
}

/// One change on its way to the device.
///
/// The device does not echo a local identifier, so a change cannot be confirmed by
/// matching identifiers. It is confirmed by reading the value back afterwards and
/// finding what we asked for.
public struct SetTransaction<Value: Equatable & Sendable>: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Still cancellable. Nothing has reached the device.
    case beforeWrite
    /// Written. Cancelling now would leave the real value unknown.
    case writtenAwaitingResponse
    /// Reading the value back to see whether the change took.
    case verifying
    /// The write was answered by silence and the session was dropped. The device may
    /// hold the new value, the old one, or something else entirely.
    case recoveryPending
    /// Reading the value back on a fresh session.
    case recoveryReading
  }

  public let revision: UInt64
  public let requestedValue: Value
  public let sessionEpoch: SessionEpoch
  public internal(set) var phase: Phase
  public internal(set) var verificationAttempts: Int

  init(
    revision: UInt64,
    requestedValue: Value,
    sessionEpoch: SessionEpoch,
    phase: Phase = .beforeWrite,
    verificationAttempts: Int = 0
  ) {
    self.revision = revision
    self.requestedValue = requestedValue
    self.sessionEpoch = sessionEpoch
    self.phase = phase
    self.verificationAttempts = verificationAttempts
  }

  /// Past the point where the caller may still call it off.
  public var isCommitted: Bool { phase != .beforeWrite }
}

/// One controllable setting: what the device confirmed, what the user asked for, and
/// the change currently travelling between them.
///
/// Separating the two values is what lets a control follow the finger immediately
/// while the confirmed value stays honest about what the device actually holds.
public struct SettingState<Value: Equatable & Sendable>: Equatable, Sendable {
  public private(set) var confirmed: Value?
  public private(set) var desired: Value?
  public private(set) var transaction: SetTransaction<Value>?
  /// The newest value asked for while a change is already in flight. Intermediate
  /// values are dropped: sending every position of a slider would flood the device.
  public private(set) var queuedLatest: Value?
  public private(set) var freshness: Freshness = .unknown
  private var nextRevision: UInt64 = 0

  public init() {}

  /// What the interface shows. The requested value wins so the control responds at
  /// once, even though it is not yet confirmed.
  public var displayed: Value? { desired ?? confirmed }

  public var isChanging: Bool { transaction != nil }

  /// A recovery read has to happen before anything else touches this setting.
  public var isRecovering: Bool {
    switch transaction?.phase {
    case .recoveryPending, .recoveryReading: true
    default: false
    }
  }

  // MARK: - Reads that arrive on their own

  /// A change made on the headphone itself, or by another host.
  public mutating func apply(notification value: Value, epoch: SessionEpoch, current: SessionEpoch) {
    guard epoch == current else { return }
    // While a change is in flight only the verification read may confirm. A
    // notification here would report whichever value the device held mid-change.
    guard transaction == nil else { return }
    confirmed = value
    freshness = .fresh
  }

  /// An ordinary read, not one issued to verify a change.
  public mutating func apply(read value: Value, epoch: SessionEpoch, current: SessionEpoch) {
    guard epoch == current else { return }
    guard transaction == nil else { return }
    confirmed = value
    freshness = .fresh
  }

  // MARK: - Making a change

  public enum ChangeRejection: Error, Equatable, Sendable {
    /// A recovery read has to establish the real value first.
    case recovering
  }

  /// Records a request to change the value. Returns the transaction to write, or
  /// `nil` when the change was merely queued behind one already in flight.
  public mutating func request(
    _ value: Value,
    epoch: SessionEpoch
  ) -> Result<SetTransaction<Value>?, ChangeRejection> {
    guard !isRecovering else { return .failure(.recovering) }

    desired = value
    guard transaction == nil else {
      // Replace rather than append: only the latest position matters.
      queuedLatest = value
      return .success(nil)
    }

    let transaction = SetTransaction(
      revision: nextRevision,
      requestedValue: value,
      sessionEpoch: epoch
    )
    nextRevision &+= 1
    self.transaction = transaction
    return .success(transaction)
  }

  /// Called once the bytes are handed to the writer. From here the change can no
  /// longer be called off.
  public mutating func markWritten() {
    guard transaction?.phase == .beforeWrite else { return }
    transaction?.phase = .writtenAwaitingResponse
  }

  public mutating func markVerifying() {
    guard transaction?.phase == .writtenAwaitingResponse else { return }
    transaction?.phase = .verifying
  }

  // MARK: - Outcomes

  public enum VerificationOutcome: Equatable, Sendable {
    case confirmed
    case retry
    case settled
  }

  /// The verification read came back.
  @discardableResult
  public mutating func apply(
    verification value: Value,
    maximumAttempts: Int
  ) -> VerificationOutcome {
    guard let transaction, transaction.phase == .verifying else { return .settled }

    if value == transaction.requestedValue {
      finish(with: value)
      return .confirmed
    }

    // A device may take a moment to apply a change, so one mismatch is not a
    // verdict. Give up only after the allowance, and then adopt what was actually
    // read: leaving the interface showing the old value when the device holds a
    // third one would be worse than either.
    let attempts = transaction.verificationAttempts + 1
    guard attempts >= maximumAttempts else {
      self.transaction?.verificationAttempts = attempts
      return .retry
    }
    finish(with: value)
    return .settled
  }

  public mutating func verificationTimedOut() {
    guard transaction != nil else { return }
    clearChange()
    freshness = .stale
  }

  /// The write itself went unanswered. The device may or may not hold the new value.
  public mutating func writeWentUnanswered() {
    guard transaction != nil else { return }
    transaction?.phase = .recoveryPending
    desired = nil
    queuedLatest = nil
    freshness = .stale
  }

  public mutating func markRecoveryReading() {
    guard transaction?.phase == .recoveryPending else { return }
    transaction?.phase = .recoveryReading
  }

  /// The recovery read succeeded on a fresh session.
  public mutating func apply(recovery value: Value) {
    guard isRecovering else { return }
    confirmed = value
    clearChange()
    freshness = .fresh
  }

  /// No session could be re-established, so what the device holds stays unknown.
  public mutating func recoveryAbandoned() {
    guard isRecovering else { return }
    clearChange()
    freshness = .stale
  }

  /// The session went away. Recovery is deliberately left alone: it is tracked apart
  /// from ordinary changes precisely so it can outlive the session that started it.
  public mutating func sessionInvalidated() {
    guard !isRecovering else {
      freshness = .stale
      return
    }
    clearChange()
    freshness = .stale
  }

  // MARK: - Private

  private mutating func finish(with value: Value) {
    confirmed = value
    freshness = .fresh
    if let queued = queuedLatest {
      // Keep showing the queued value; dropping it here would make the control jump
      // back before the next change is even sent.
      desired = queued
      queuedLatest = nil
      transaction = SetTransaction(
        revision: nextRevision,
        requestedValue: queued,
        sessionEpoch: transaction?.sessionEpoch ?? SessionEpoch(0)
      )
      nextRevision &+= 1
    } else {
      clearChange()
    }
  }

  private mutating func clearChange() {
    desired = nil
    queuedLatest = nil
    transaction = nil
  }
}
