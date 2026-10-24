import AVFoundation
import Testing

@testable import SpatialAudioKit

// カメラ選びの約束: 選んだカメラが接続中ならそれ、無ければ使用中のもの、それも
// 無ければ内蔵、内蔵も無ければ先頭。並びは 内蔵 → 外付け → Continuity Camera で、
// iPhone は選ばれない限り Mac につないだカメラより後ろに来る。

private let builtIn = CameraDevice(id: "builtin", name: "Built-in", kind: .builtIn)
private let webcam = CameraDevice(id: "webcam", name: "Webcam", kind: .external)
private let otherWebcam = CameraDevice(id: "webcam-2", name: "Webcam 2", kind: .external)
private let phone = CameraDevice(id: "phone", name: "Phone", kind: .continuity)

@Test("選んだカメラが接続中ならそれを使う")
func usesThePreferredCamera() {
  let chosen = CameraSelection.choose(from: [builtIn, webcam], preferredID: "webcam", currentID: nil)
  #expect(chosen == webcam)
}

@Test("選んだカメラが未接続なら内蔵へ戻る")
func fallsBackToTheBuiltInCamera() {
  let chosen = CameraSelection.choose(from: [webcam, builtIn], preferredID: "gone", currentID: nil)
  #expect(chosen == builtIn)
}

@Test("内蔵カメラが無ければ先頭")
func fallsBackToTheFirstCamera() {
  let chosen = CameraSelection.choose(from: [webcam, phone], preferredID: "gone", currentID: nil)
  #expect(chosen == webcam)
}

@Test("選択が無ければ、並び順に関わらず内蔵")
func noPreferenceMeansTheBuiltInCamera() {
  let chosen = CameraSelection.choose(from: [webcam, builtIn], preferredID: nil, currentID: nil)
  #expect(chosen == builtIn)
}

@Test("選んだカメラが無いあいだは使用中のカメラに留まる（別のカメラの抜き差しで飛ばない）")
func staysOnTheCurrentCamera() {
  let chosen = CameraSelection.choose(
    from: [otherWebcam, webcam], preferredID: "gone", currentID: "webcam"
  )
  #expect(chosen == webcam)
}

@Test("選んだカメラは使用中のカメラより優先（再接続されたら戻る）")
func thePreferredCameraBeatsTheCurrentOne() {
  let chosen = CameraSelection.choose(
    from: [builtIn, webcam], preferredID: "webcam", currentID: "builtin"
  )
  #expect(chosen == webcam)
}

@Test("使用中のカメラも消えていれば内蔵へ")
func aVanishedCurrentCameraFallsBack() {
  let chosen = CameraSelection.choose(from: [webcam, builtIn], preferredID: nil, currentID: "gone")
  #expect(chosen == builtIn)
}

@Test("一覧が空なら何も選ばない")
func anEmptyListChoosesNothing() {
  #expect(CameraSelection.choose(from: [], preferredID: "webcam", currentID: "builtin") == nil)
}

@Test("並びは 内蔵 → 外付け → Continuity Camera、同じ種類の中は検出順のまま")
func ordersByKindKeepingDiscoveryOrder() {
  let ordered = CameraSelection.ordered([phone, otherWebcam, builtIn, webcam])
  #expect(ordered == [builtIn, otherWebcam, webcam, phone])
}

@Test("切断通知の対象は、列挙にまだ残っていても一覧から外す")
func aDepartedCameraIsDropped() {
  let list = CameraSelection.reconcile([builtIn, webcam], arrived: nil, departedID: "webcam")
  #expect(list == [builtIn])
}

@Test("接続通知の対象は、列挙が追いついていなくても一覧に入る")
func anArrivedCameraIsAdded() {
  let list = CameraSelection.reconcile([phone, builtIn], arrived: webcam, departedID: nil)
  #expect(list == [builtIn, webcam, phone])
}

@Test("列挙済みのカメラの接続通知で重複しない")
func anAlreadyListedArrivalIsNotDuplicated() {
  let list = CameraSelection.reconcile([builtIn, webcam], arrived: webcam, departedID: nil)
  #expect(list == [builtIn, webcam])
}

@Test("Info.plist の宣言が無いと iPhone は外付けに見える — フラグで Continuity と見分ける")
func theContinuityFlagWinsOverTheDeviceType() {
  #expect(CameraDevice.Kind(deviceType: .external, isContinuityCamera: true) == .continuity)
  #expect(CameraDevice.Kind(deviceType: .continuityCamera, isContinuityCamera: true) == .continuity)
}

@Test("内蔵・外付けを種別で見分け、顔を追えない種類（デスクビュー）は扱わない")
func kindsFollowTheDeviceType() {
  #expect(CameraDevice.Kind(deviceType: .builtInWideAngleCamera, isContinuityCamera: false) == .builtIn)
  #expect(CameraDevice.Kind(deviceType: .external, isContinuityCamera: false) == .external)
  #expect(CameraDevice.Kind(deviceType: .deskViewCamera, isContinuityCamera: false) == nil)
}

@Test("探索する種類に内蔵・外付け・Continuity Camera を含む")
func discoveryCoversEveryUsableKind() {
  let types = CameraDevice.discoverableTypes
  #expect(types.contains(.builtInWideAngleCamera))
  #expect(types.contains(.external))
  #expect(types.contains(.continuityCamera))
  #expect(!types.contains(.deskViewCamera))
}
