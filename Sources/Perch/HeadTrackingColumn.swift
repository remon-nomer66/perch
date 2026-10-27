import SpatialAudioKit
import SwiftUI

/// The right three fifths of the spatial-audio sheet: camera head tracking. The toggle
/// is gated on the spatialiser being on — orientation goes nowhere without a running
/// engine — and every state the camera can be in (permission, calibration, tracking,
/// lost, facing away) is said out loud, because an active camera must never be a
/// mystery. For the same reason the heading names the camera that will light up.
struct HeadTrackingColumn: View {
  @ObservedObject var spatial: SpatialAudioController
  @ObservedObject var headTracking: HeadTrackingController

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      // The camera rides the heading row: the sheet's height is fixed, and a row of
      // its own would push the status line out of the slot.
      HStack(spacing: 8) {
        Text(L("ヘッドトラッキング", "Head Tracking"))
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.white.opacity(0.45))
          .fixedSize()
          .layoutPriority(1)
        Spacer(minLength: 0)
        if spatial.isAvailable {
          CameraChooser(headTracking: headTracking)
        }
      }

      if spatial.isAvailable {
        SwitchRow(
          title: L("カメラで頭に追従", "Follow with the camera"),
          isOn: headTracking.isEnabled
        ) {
          headTracking.setEnabled($0)
        }
        .disabled(!spatial.isEnabled)
        .opacity(spatial.isEnabled ? 1 : 0.45)

        if !spatial.isEnabled {
          caption(
            L("空間オーディオをオンにすると使えます。", "Turn on Spatial Audio to use this.")
          )
        } else {
          if headTracking.isEnabled {
            SwitchRow(
              title: L("距離も反映（実験的）", "Distance too (experimental)"),
              isOn: headTracking.distanceEnabled
            ) {
              headTracking.distanceEnabled = $0
            }
          }
          status
        }
      } else {
        caption(
          L("空間オーディオと同じく macOS 14.4 以降が必要です。", "Requires macOS 14.4 or later, like Spatial Audio.")
        )
      }
    }
    // The camera list is read here, in the background, each time the column appears —
    // not at launch: the first enumeration is slow and most launches never show this
    // sheet. Later reads are cheap and catch what no notification reports, like the
    // built-in camera coming back when the lid opens.
    .task {
      if spatial.isAvailable {
        await headTracking.loadCameras()
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch headTracking.status {
    case .off:
      caption(
        L("頭を回すと音場が部屋に残るように追従します。", "Keeps the sound field in place as you turn your head.")
      )
    case .requestingPermission:
      caption(L("カメラの許可を確認しています…", "Waiting for camera permission…"))
    case .calibrating:
      caption(
        L("較正中 — 正面を向いたままお待ちください。", "Calibrating — keep facing forward.")
      )
    case .tracking:
      HStack(spacing: 8) {
        caption(L("追跡中（カメラ使用中）", "Tracking (camera in use)"))
        SegmentButton(
          title: L("再センター", "Recenter"), isSelected: false, fixedWidth: false
        ) {
          headTracking.recenter()
        }
      }
    case .faceLost:
      caption(
        L("顔を見失っています — 音場をゆっくり正面へ戻します。", "Face lost — easing the sound field back to front.")
      )
    case .facingAway:
      // No recenter here: with the face out of view there is no direction to take as
      // the new front.
      caption(
        L("後ろ向き — 音場を背後へ回します。", "Facing away — turning the sound field behind you.")
      )
    case .denied:
      warning(
        L(
          "カメラの許可がありません。設定 → プライバシーとセキュリティ → カメラ で Perch をオンにしてください。",
          "Camera access is not allowed. Turn Perch on in Settings → Privacy & Security → Camera."
        )
      )
    case .failed(let message):
      warning(message)
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9))
      .foregroundStyle(.white.opacity(0.5))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func warning(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9))
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Which camera head tracking looks through.
///
/// A menu only when there is something to choose: with a single camera the name is
/// shown as plain text — it still says which camera will turn on, without offering a
/// choice that is not there. A saved pick that is unplugged keeps the menu even with
/// one camera left, because that menu is where the user learns the pick is kept and
/// will be used again once it is back. Choosing while tracking switches at once.
/// Nothing is shown until the list has been read, rather than a "No camera" that
/// would only be true for the second it takes to look.
private struct CameraChooser: View {
  @ObservedObject var headTracking: HeadTrackingController

  var body: some View {
    if let cameras = headTracking.cameras {
      if let current = headTracking.effectiveCamera {
        if cameras.count > 1 || headTracking.isPreferredCameraMissing {
          menu(current: current, cameras: cameras)
        } else {
          label(current.name, showsChevron: false)
        }
      } else {
        label(L("カメラなし", "No camera"), showsChevron: false)
      }
    }
  }

  private func menu(current: CameraDevice, cameras: [CameraDevice]) -> some View {
    Menu {
      // Toggles rather than a picker: a toggle reports a click on the item that is
      // already checked, and that is how the stand-in camera becomes the new choice
      // while the old pick is unplugged — a picker sees no change there and stays quiet.
      ForEach(cameras) { camera in
        Toggle(
          camera.name,
          isOn: Binding(
            get: { camera.id == current.id },
            set: { _ in headTracking.selectCamera(id: camera.id) }
          )
        )
      }

      if headTracking.isPreferredCameraMissing {
        Divider()
        Text(Self.missingNote)
      }
    } label: {
      label(current.name, showsChevron: true)
    }
    // The stock pull-down draws a light bezel that has no place on the panel's black
    // backdrop; a plain button keeps the label exactly as drawn.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help(headTracking.isPreferredCameraMissing ? Self.missingNote : L("使うカメラ", "Camera to use"))
  }

  private func label(_ text: String, showsChevron: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "camera")
        .font(.system(size: 8))
      Text(text)
        .lineLimit(1)
        .truncationMode(.middle)
      if showsChevron {
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 7, weight: .semibold))
      }
    }
    .font(.system(size: 9))
    .foregroundStyle(.white.opacity(showsChevron ? 0.75 : 0.5))
    .contentShape(Rectangle())
  }

  private static var missingNote: String {
    L(
      "選んだカメラは未接続です。つなぎ直すと、そのカメラに戻ります。",
      "The chosen camera is disconnected. It is used again once reconnected."
    )
  }
}
