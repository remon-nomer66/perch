import Foundation
import TandemCore
import Testing

@testable import TandemSession

private let router = TandemRouter()

private func frame(_ dataType: UInt8, sequence: UInt8 = 0) throws -> TandemFrame {
  try TandemFrame(dataType: dataType, sequence: sequence, payload: Data([0x42]))
}

@Test func dataFramesAreAcknowledgedImmediately() throws {
  let incoming = try frame(TandemFrame.table1DataType, sequence: 0)
  let output = router.route([incoming])

  #expect(output.events == [.data(incoming)])
  #expect(output.acknowledgements.count == 1)
  #expect(output.acknowledgements[0].dataType == TandemFrame.ackDataType)
  #expect(output.acknowledgements[0].sequence == 1, "the acknowledgement inverts the sequence")
}

@Test func anAcknowledgementIsNotAcknowledgedBack() throws {
  let incoming = try TandemFrame(
    dataType: TandemFrame.ackDataType,
    sequence: 1,
    payload: Data()
  )
  let output = router.route([incoming])

  #expect(output.events == [.acknowledgement(sequence: 1)])
  #expect(output.acknowledgements.isEmpty, "acknowledging an acknowledgement never terminates")
}

@Test func sequenceAlternationIsPreservedPerFrame() throws {
  let first = try frame(TandemFrame.table1DataType, sequence: 0)
  let second = try frame(TandemFrame.table2DataType, sequence: 1)

  let output = router.route([first, second])

  #expect(output.acknowledgements.map(\.sequence) == [1, 0])
}

@Test func framesThatDoNotWantAnAcknowledgementGetNone() throws {
  // The device marks some notification types as not needing a reply.
  let quiet = try frame(0x10)
  #expect(!quiet.requiresAcknowledgement)

  let output = router.route([quiet])

  #expect(output.events == [.data(quiet)])
  #expect(output.acknowledgements.isEmpty)
}

@Test func dataAndAcknowledgementsInOneReadKeepTheirOrder() throws {
  let ack = try TandemFrame(dataType: TandemFrame.ackDataType, sequence: 0, payload: Data())
  let data = try frame(TandemFrame.table1DataType, sequence: 1)

  let output = router.route([ack, data])

  #expect(output.events == [.acknowledgement(sequence: 0), .data(data)])
  #expect(output.acknowledgements.count == 1)
}

@Test func anEmptyReadProducesNothing() {
  #expect(router.route([]).isEmpty)
}
