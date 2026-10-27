import Foundation

/// The operation a BMAP frame carries, held in the low nibble of the flags byte.
///
/// BMAP names every message by an `(fblock, function)` pair plus one of these
/// operators, the way HTTP pairs a path with a verb. GET asks for a value, SET
/// writes one without a reply, SETGET writes and asks for the stored value back,
/// STATUS answers a GET or arrives unsolicited, ERROR carries a `BmapErrorCode`,
/// and START/RESULT/PROCESSING drive the longer procedures. Only 0...7 are
/// defined; a flags byte whose nibble is 8...15 is treated as a framing error so a
/// desynchronised stream is noticed rather than silently mis-parsed.
public enum BmapOperator: UInt8, Equatable, Sendable, CaseIterable {
  case set = 0
  case get = 1
  case setGet = 2
  case status = 3
  case error = 4
  case start = 5
  case result = 6
  case processing = 7
}
