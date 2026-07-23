import Foundation
import Testing

@testable import TandemCore

@Test func featureStateKeepsPreviousValueWhileLoadingOrAfterFailure() {
  let loading = TandemFeatureState<Int>.loading(previous: 42)
  let failed = TandemFeatureState<Int>.failed(message: "timeout", previous: 42)

  #expect(loading.value == 42)
  #expect(failed.value == 42)
}

@Test func featureStateDoesNotInventAValue() {
  #expect(TandemFeatureState<Int>.notFetched.value == nil)
  #expect(TandemFeatureState<Int>.unsupported.value == nil)
  #expect(TandemFeatureState<Int>.unavailable(reason: "通話中").value == nil)

  let readAt = Date(timeIntervalSince1970: 1_234)
  let available = TandemFeatureState<Int>.available(value: 7, readAt: readAt)
  #expect(available.value == 7)
}
