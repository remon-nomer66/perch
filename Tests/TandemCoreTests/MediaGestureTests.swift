import Foundation
import Testing

@testable import TandemCore

// The payloads below are exactly what a headset sent over the control channel while an
// app held it open and the wearer used the touch panel. Decoding them proves the app
// can recover the intended action and re-issue the ones the headset withholds.

@Test func decodesTheDoubleTapPauseAndPlayOperations() {
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x07,
    0x6F, 0x70, 0x50, 0x61, 0x75, 0x73, 0x65, 0x00])) == .pause)  // "opPause"
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x06,
    0x6F, 0x70, 0x50, 0x6C, 0x61, 0x79, 0x00])) == .play)         // "opPlay"
}

@Test func decodesTheForwardAndBackwardSwipeOperations() {
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x06,
    0x6F, 0x70, 0x4E, 0x65, 0x78, 0x74, 0x00])) == .next)          // "opNext"
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x06,
    0x6F, 0x70, 0x50, 0x72, 0x65, 0x76, 0x00])) == .previous)      // "opPrev"
}

@Test func decodesTheVolumeOperationsButMarksThemNotForwarded() {
  let up = TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x07,
    0x6F, 0x70, 0x56, 0x6F, 0x6C, 0x55, 0x70, 0x00]))              // "opVolUp"
  let down = TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x09,
    0x6F, 0x70, 0x56, 0x6F, 0x6C, 0x44, 0x6F, 0x77, 0x6E, 0x00]))  // "opVolDown"
  #expect(up == .volumeUp)
  #expect(down == .volumeDown)
  // The headset already changed its own volume, so these must not be re-issued.
  #expect(up?.isTransport == false)
  #expect(down?.isTransport == false)
}

@Test func transportOperationsAreTheOnesTheHeadsetWithholds() {
  #expect(TandemMediaGesture.play.isTransport)
  #expect(TandemMediaGesture.pause.isTransport)
  #expect(TandemMediaGesture.next.isTransport)
  #expect(TandemMediaGesture.previous.isTransport)
}

@Test func ignoresThePhysicalKeyLabelSoAGestureIsNotCountedTwice() {
  // The same double-tap also arrives as "keyRDoubleTap": same command, but the third
  // byte is the label length, not zero. Decoding it would fire the action a second
  // time.
  let keyLabel = Data([0xC9, 0x01, 0x0D, 0x6B, 0x65, 0x79, 0x52, 0x44, 0x6F, 0x75,
    0x62, 0x6C, 0x65, 0x54, 0x61, 0x70, 0x00, 0x00])  // "keyRDoubleTap"
  #expect(TandemMediaGesture.decode(payload: keyLabel) == nil)

  let rightFlick = Data([0xC9, 0x01, 0x0E, 0x6B, 0x65, 0x79, 0x52, 0x52, 0x69, 0x67,
    0x68, 0x74, 0x46, 0x6C, 0x69, 0x63, 0x6B, 0x00, 0x00])  // "keyRRightFlick"
  #expect(TandemMediaGesture.decode(payload: rightFlick) == nil)
}

@Test func ignoresPlaybackStateAndVolumeLevelEchoes() {
  // A5 announces the playback state (01 playing, 02 paused); A9 announces the absolute
  // volume. Neither is an operation the wearer just performed.
  #expect(TandemMediaGesture.decode(payload: Data([0xA5, 0x01, 0x00, 0x02, 0x00])) == nil)
  #expect(TandemMediaGesture.decode(payload: Data([0xA5, 0x01, 0x00, 0x01, 0x00])) == nil)
  #expect(TandemMediaGesture.decode(payload: Data([0xA9, 0x20, 0x0A])) == nil)
}

@Test func ignoresAnUnknownOperationRatherThanGuessing() {
  // A future action the app does not map yet must not be mistaken for one it does.
  let unknown = Data([0xC9, 0x01, 0x00, 0x05, 0x6F, 0x70, 0x41, 0x53, 0x4D, 0x00])  // "opASM"
  #expect(TandemMediaGesture.decode(payload: unknown) == nil)
}

@Test func refusesTruncatedFramesWithoutCrashing() {
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00])) == nil)
  #expect(TandemMediaGesture.decode(payload: Data([0xC9, 0x01, 0x00, 0x09, 0x6F, 0x70])) == nil)
  #expect(TandemMediaGesture.decode(payload: Data()) == nil)
}
