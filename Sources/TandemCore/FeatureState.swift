import Foundation

/// A feature value whose absence has an explicit meaning.  UI code must never
/// replace these states with a plausible-looking default value.
public enum TandemFeatureState<Value: Equatable & Sendable>: Equatable, Sendable {
  case notFetched
  case loading(previous: Value?)
  case unsupported
  case unavailable(reason: String)
  case available(value: Value, readAt: Date)
  case failed(message: String, previous: Value?)

  public var value: Value? {
    switch self {
    case .loading(let previous), .failed(_, let previous):
      return previous
    case .available(let value, _):
      return value
    case .notFetched, .unsupported, .unavailable:
      return nil
    }
  }
}
