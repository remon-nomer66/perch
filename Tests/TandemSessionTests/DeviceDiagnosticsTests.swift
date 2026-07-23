import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Answers every read-only GET with a recognisable echo, and records what was asked,
/// so the tests can see both the captures taken and the requests never sent.
private final class RecordingRequester: SessionRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [[UInt8]] = []

  var requests: [[UInt8]] {
    lock.withLock { sent }
  }

  func request(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    let payload = [UInt8](try build(0).payload)
    lock.withLock { sent.append(payload) }

    // Reply `<command+1> <inquiry> AA` — the shape the matcher expects for any family.
    let reply = try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 1,
      payload: Data([payload[0] + 1, payload[1], 0xAA])
    )
    guard matching(reply) else { throw ChannelFailure.openTimedOut }
    return reply
  }
}

private func declared(_ codes: [UInt8]) -> [TandemSupportFunction] {
  codes.map { TandemSupportFunction(code: $0, version: 0) }
}

@Test func aDeclaredAssignableSettingIsReadByItsOffsetInquiry() async {
  let requester = RecordingRequester()
  let captures = await DeviceDiagnostics().rawCaptures(
    declaring: declared([0xF3]),
    over: requester
  )

  // ASSIGNABLE_SETTING (0xF3) lives in the system family: inquiry = code - 0xF0.
  #expect(captures.contains { $0.label == "system.F3.capability" && $0.request == [0xF0, 0x03] })
  #expect(captures.contains { $0.label == "system.F3.parameter" && $0.request == [0xF6, 0x03] })
}

@Test func aDeclaredPlaybackControllerIsReadByItsOffsetInquiry() async {
  let requester = RecordingRequester()
  let captures = await DeviceDiagnostics().rawCaptures(
    declaring: declared([0xA3]),
    over: requester
  )

  #expect(captures.contains { $0.label == "playback.A3.capability" && $0.request == [0xA0, 0x03] })
  #expect(captures.contains { $0.label == "playback.A3.parameter" && $0.request == [0xA6, 0x03] })
}

@Test func speakToChatCodesAreNotAskedTwice() async {
  let requester = RecordingRequester()
  let captures = await DeviceDiagnostics().rawCaptures(
    declaring: declared([TandemSpeakToChatProtocol.functionCodeType2]),
    over: requester
  )

  // The speak-to-chat block already reads 0xFC on its own inquiry; the system sweep
  // must leave it alone or the same conversation is captured twice.
  #expect(captures.contains { $0.label == "s2c.capability" })
  #expect(!captures.contains { $0.label.hasPrefix("system.FC") })
}

@Test func nothingIsAskedForUndeclaredFunctions() async {
  let requester = RecordingRequester()
  let captures = await DeviceDiagnostics().rawCaptures(
    declaring: declared([0x21]),
    over: requester
  )

  #expect(captures.isEmpty)
  #expect(requester.requests.isEmpty)
}
