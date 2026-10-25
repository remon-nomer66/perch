import AVFoundation
import Foundation
import Testing
import os

@testable import SpatialAudioKit

// システムのカメラ一覧の約束: 作っただけでは列挙しない、一度列挙した後は接続・切断の
// 通知ごとに一覧を配る、手放したら通知を受けない。通知は専用のセンターへ自分で流し、
// 列挙は差し替えるので、実デバイスには触れない。

private let builtIn = CameraDevice(id: "builtin", name: "Built-in", kind: .builtIn)

/// 差し替えた列挙が呼ばれた回数。列挙は main の外からも呼ばれるのでロックで守る。
private final class EnumerationCount: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)
  var value: Int { count.withLock { $0 } }
  func increment() { count.withLock { $0 += 1 } }
}

@MainActor
private final class Received {
  var lists: [[CameraDevice]] = []
}

@MainActor
private func makeCatalog(
  center: NotificationCenter, count: EnumerationCount
) -> (SystemCameraCatalog, Received) {
  let catalog = SystemCameraCatalog(center: center) {
    count.increment()
    return [builtIn]
  }
  let received = Received()
  catalog.onChange = { received.lists.append($0) }
  return (catalog, received)
}

/// 通知の配達（メインキュー経由）を待つ。
@MainActor
private func settle(until condition: () -> Bool = { false }) async {
  for _ in 0..<50 where !condition() {
    try? await Task.sleep(for: .milliseconds(2))
  }
}

@MainActor
@Test("作っただけでは列挙しない。一度も列挙していない間の通知でも列挙しない")
func nothingIsEnumeratedBeforeTheFirstLook() async {
  let center = NotificationCenter()
  let count = EnumerationCount()
  let (catalog, received) = makeCatalog(center: center, count: count)
  #expect(count.value == 0)

  // 最初の列挙は重い（CoreMediaIO の読み込み）。音声機器の抜き差しなどで来る通知に
  // 釣られて、それを main で払わない。
  center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
  await settle()
  #expect(count.value == 0)
  #expect(received.lists.isEmpty)
  _ = catalog
}

@MainActor
@Test("一度列挙した後は、接続・切断の通知のたびに一覧を配る")
func noticesAfterTheFirstLookDeliverTheList() async {
  let center = NotificationCenter()
  let count = EnumerationCount()
  let (catalog, received) = makeCatalog(center: center, count: count)
  #expect(catalog.currentCameras() == [builtIn])

  center.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
  await settle { received.lists.count == 1 }
  center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
  await settle { received.lists.count == 2 }
  #expect(received.lists == [[builtIn], [builtIn]])
}

@MainActor
@Test("裏で読んだ一覧も「列挙済み」に数え、以後の通知を配る")
func aBackgroundLoadCountsAsTheFirstLook() async {
  let center = NotificationCenter()
  let count = EnumerationCount()
  let (catalog, received) = makeCatalog(center: center, count: count)
  #expect(await catalog.loadCameras() == [builtIn])

  center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
  await settle { received.lists.count == 1 }
  #expect(received.lists == [[builtIn]])
}

@MainActor
@Test("手放したカタログは通知を受けない")
func aReleasedCatalogStopsListening() async {
  let center = NotificationCenter()
  let count = EnumerationCount()
  var catalog: SystemCameraCatalog? = SystemCameraCatalog(center: center) {
    count.increment()
    return [builtIn]
  }
  _ = catalog?.currentCameras()
  weak let released = catalog
  catalog = nil
  #expect(released == nil)

  center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
  await settle()
  #expect(count.value == 1)
}
