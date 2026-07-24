import Foundation
import Testing

@testable import BoseCore

@Test func errorFrameExposesKnownCode() throws {
  // Runtime (8) is the refusal an Ultra 2 gives to a state-forbidden write.
  let frame = try BmapFrame(fblock: 1, function: 5, op: .error, payload: Data([0x08]))
  #expect(frame.isError)
  #expect(frame.rawErrorCode == 0x08)
  #expect(frame.errorCode == .runtime)
}

@Test func operatorNotSupportedIsTheAuthRefusal() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .error, payload: Data([0x05]))
  #expect(frame.errorCode == .operatorNotSupported)
}

@Test func unknownErrorCodeIsStillVisible() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .error, payload: Data([0x63]))
  #expect(frame.rawErrorCode == 0x63)
  #expect(frame.errorCode == nil)
}

@Test func nonErrorFrameHasNoErrorCode() throws {
  let frame = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  #expect(frame.isError == false)
  #expect(frame.rawErrorCode == nil)
  #expect(frame.errorCode == nil)
}

@Test func emptyErrorPayloadHasNoCode() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .error)
  #expect(frame.isError)
  #expect(frame.rawErrorCode == nil)
}
