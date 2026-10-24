import Combine
import Testing

@testable import Perch

// `@Published` announces a change from the property's `willSet`. A subscriber that
// reads the store back — the notch controller reading the virtual-notch setting
// through its closure, say — found the old value there, so switching the virtual
// notch on or off rebuilt against the setting it was leaving.

@MainActor
private final class Setting: ObservableObject {
  @Published var isOn = false
}

@MainActor
private final class Seen {
  var values: [Bool] = []
}

@MainActor
@Test("Straight off the publisher, the store still holds the old value")
func willSetDeliversBeforeTheAssignment() {
  let setting = Setting()
  let seen = Seen()
  let subscription = setting.$isOn.dropFirst().sink { _ in seen.values.append(setting.isOn) }
  setting.isOn = true
  #expect(seen.values == [false])
  subscription.cancel()
}

@MainActor
@Test("After the assignment settles, a subscriber reading the store finds the new value")
func afterAssignmentReadsTheNewValue() async {
  let setting = Setting()
  let seen = Seen()
  let subscription = setting.$isOn
    .dropFirst()
    .afterAssignment()
    .sink { _ in seen.values.append(setting.isOn) }
  setting.isOn = true
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while seen.values.isEmpty, ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
  #expect(seen.values == [true])
  subscription.cancel()
}
