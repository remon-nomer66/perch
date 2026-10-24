import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Synthetic, in the documentation range of no real vendor. It must never surface.
private let address = "02:00:00:00:00:01"
private let device = DeviceIdentity(address)

@Test func eventsAreLoggedWithoutTheDeviceTheyConcern() {
  let events: [SessionEvent] = [
    .defaultOutputChanged(device), .defaultOutputChanged(nil),
    .didWake(device), .didWake(nil),
    .channelOpened(ConnectionAttempt(3)), .sessionFault(.writeStalled),
    .controlContended(ConnectionAttempt(3)), .verificationFailedPermanently,
  ]
  for event in events {
    let name = SessionLog.name(of: event)
    #expect(!name.contains(address), "\(name) carries the address")
    #expect(!name.contains(device.rawValue))
    #expect(!name.isEmpty)
  }
  // Enough survives to read a log by: which event, and whether a device was named.
  #expect(SessionLog.name(of: .defaultOutputChanged(device)) == "defaultOutputChanged(device)")
  #expect(SessionLog.name(of: .defaultOutputChanged(nil)) == "defaultOutputChanged(none)")
  #expect(SessionLog.name(of: .sessionFault(.responseTimedOut)) == "sessionFault(responseTimedOut)")
}

@Test func phasesAreLoggedByName() {
  #expect(SessionLog.name(of: .suspended(resume: .ready)) == "suspended(ready)")
  #expect(SessionLog.name(of: .sleeping(resume: .blocked(.contended))) == "sleeping(blocked: contended)")
  #expect(SessionLog.name(of: .incompatible) == "incompatible")
}

@Test func aFailureIsLoggedByItsProtocolShapeOnly() {
  // The session's own failure types say nothing about whose device it was.
  #expect(SessionLog.reason(ChannelFailure.openRejected(-1)) == "openRejected(-1)")
  #expect(SessionLog.reason(SessionRequestFailure.failed(.noReply)) == "failed(noReply)")
  #expect(
    SessionLog.reason(TandemHandshakeError.invalidProtocolPayloadLength(3))
      == TandemHandshakeError.invalidProtocolPayloadLength(3).description
  )

  // Anything else is named by its type alone: its description could hold anything,
  // a model or unit name included.
  struct Unrecognised: Error, CustomStringConvertible {
    var description: String { "talking to \(address)" }
  }
  let reason = SessionLog.reason(Unrecognised())
  #expect(!reason.contains(address))
  #expect(reason.contains("Unrecognised"))
}

@Test func aRequestIsLoggedByItsCommandAndInquiry() {
  #expect(SessionLog.label(ofRequest: Data([0x22, 0x01, 0x05])) == "22 01")
  #expect(SessionLog.label(ofRequest: Data([0x12])) == "12")
}
