import Foundation
import Testing

@testable import TandemCore

private func payload(_ bytes: [UInt8]) -> Data { Data(bytes) }

/// The operation shape: `C9 01 00 <len> <ascii> 00`.
private let opPlay: [UInt8] = [0xC9, 0x01, 0x00, 0x06] + Array("opPlay".utf8) + [0x00]

/// The physical-key shape: `C9 01 <len> <ascii> 00 00`.
private let keyDoubleTap: [UInt8] =
  [0xC9, 0x01, 0x0D] + Array("keyRDoubleTap".utf8) + [0x00, 0x00]

@Test func anOperationNotificationIsKeptWithItsNameAsTheLabel() {
  let log = TandemGestureNotificationLog().recording(payload(opPlay))

  let capture = try! #require(log.captures.first)
  #expect(capture.label == "notify.opPlay")
  #expect(capture.request.isEmpty)
  #expect(capture.response == opPlay)
}

@Test func aPhysicalKeyNotificationIsKeptWithItsNameAsTheLabel() {
  let log = TandemGestureNotificationLog().recording(payload(keyDoubleTap))

  #expect(log.captures.map(\.label) == ["notify.keyRDoubleTap"])
}

@Test func aFrameFromAnotherCommandFamilyIsNotRecorded() {
  // A volume-level report (0xA9) is a notification, but not the gesture log's.
  let log = TandemGestureNotificationLog().recording(payload([0xA9, 0x20, 0x40]))

  #expect(log.captures.isEmpty)
}

@Test func aPayloadCarryingNonTokenTextIsNotRecorded() {
  // Multi-byte text or spaced words could carry personal data (a track title),
  // so anything beyond a single bare ASCII token is refused.
  let spaced: [UInt8] = [0xC9, 0x01, 0x00, 0x07] + Array("op Play".utf8) + [0x00]
  let multibyte: [UInt8] = [0xC9, 0x01, 0x00, 0x06] + Array("曲名".utf8) + [0x00]

  var log = TandemGestureNotificationLog()
  log = log.recording(payload(spaced))
  log = log.recording(payload(multibyte))

  #expect(log.captures.isEmpty)
}

@Test func anOverlongPayloadIsNotRecorded() {
  let oversized: [UInt8] = [0xC9, 0x01, 0x00, 0x1E] + Array(repeating: 0x61, count: 30) + [0x00]

  let log = TandemGestureNotificationLog().recording(payload(oversized))

  #expect(log.captures.isEmpty)
}

@Test func theSamePayloadIsKeptOnce() {
  var log = TandemGestureNotificationLog()
  log = log.recording(payload(opPlay))
  log = log.recording(payload(opPlay))
  log = log.recording(payload(keyDoubleTap))

  #expect(log.captures.map(\.label) == ["notify.opPlay", "notify.keyRDoubleTap"])
}

@Test func tokensListTheHeardGestureNamesInArrivalOrder() {
  var log = TandemGestureNotificationLog()
  log = log.recording(payload(opPlay))
  log = log.recording(payload(keyDoubleTap))
  let unrelated = TandemRawCapture(label: "eq.capability", request: [0x50], response: [0x51])

  let tokens = TandemGestureNotificationLog.tokens(in: log.captures + [unrelated])

  #expect(tokens == ["opPlay", "keyRDoubleTap"])
}

@Test func theLogStopsGrowingAtItsCapacity() {
  var log = TandemGestureNotificationLog()
  for index in 0..<(TandemGestureNotificationLog.capacity + 8) {
    let name = Array(String(format: "op%03d", index).utf8)
    log = log.recording(payload([0xC9, 0x01, 0x00, UInt8(name.count)] + name + [0x00]))
  }

  #expect(log.captures.count == TandemGestureNotificationLog.capacity)
}
