import BoseCore
import Testing

@testable import Perch

private func component(_ percent: Int, id: UInt8) -> BmapBatteryComponent {
  BmapBatteryComponent(percent: percent, minutesRemaining: nil, componentId: id)
}

@Test func noBatteryComponentsIsUnknown() {
  #expect(BoseDeviceController.batteryLayout(from: []) == .unknown)
}

@Test func oneComponentIsTheWholeHeadset() {
  #expect(BoseDeviceController.batteryLayout(from: [component(72, id: 0)]) == .single(72))
}

/// Which enclosure each component belongs to is device-defined and not declared in the
/// payload, so several readings are numbered in report order rather than labelled L / R /
/// case — a label the notch would otherwise get backwards on a device that orders them
/// differently.
@Test func severalComponentsAreNumberedNotLabelledLeftRight() {
  let layout = BoseDeviceController.batteryLayout(
    from: [component(80, id: 2), component(75, id: 1), component(60, id: 3)]
  )
  #expect(
    layout == .numbered([
      .init(slot: 1, percent: 80),
      .init(slot: 2, percent: 75),
      .init(slot: 3, percent: 60),
    ])
  )
}

@Test func twoComponentsStillNumber() {
  let layout = BoseDeviceController.batteryLayout(from: [component(90, id: 1), component(88, id: 2)])
  #expect(layout == .numbered([.init(slot: 1, percent: 90), .init(slot: 2, percent: 88)]))
}
