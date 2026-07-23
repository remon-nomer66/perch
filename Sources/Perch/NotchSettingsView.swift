import NotchKit
import SwiftUI

/// Adjusts how large the notch bar and the panel are drawn.
///
/// The changes take effect while the sliders move: the notch is right there on the
/// same screen, so a preview inside this window would be a worse view of the result
/// than the result itself.
struct NotchSettingsView: View {
  @ObservedObject var store: NotchAppearanceStore
  @ObservedObject var settings: AppSettingsStore

  private let limits = NotchAppearance.limits

  var body: some View {
    Form {
      Section(L("ノッチ", "Notch")) {
        Toggle(L("ノッチに表示", "Show in the notch"), isOn: $settings.isNotchEnabled)
        Text(
          L(
            "オフにするとノッチのパネルは表示されません。機器の操作は「一般」から行えます。",
            "When off, the notch panel is hidden. The device can still be controlled from “General”."
          )
        )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)

        Picker(L("表示の仕方", "Display style"), selection: $settings.notchDisplayMode) {
          Text(L("常に表示", "Always shown")).tag(NotchDisplayMode.always)
          Text(L("ホバーで表示", "Show on hover")).tag(NotchDisplayMode.onHover)
        }
        Text(
          L(
            "「ホバーで表示」では普段は何もないノッチのままです。機器の接続時に約5秒だけ表示され、"
              + "ノッチにポインタを載せると縮小表示、クリックで展開します。",
            "With “Show on hover” the notch normally stays bare. The bar shows for about "
              + "5 seconds when a device connects, appears while the pointer is on the "
              + "notch, and expands on click."
          )
        )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)

        Toggle(L("全画面表示中は隠す", "Hide during full screen"), isOn: $settings.hidesNotchInFullScreen)
        Text(
          L(
            "ノッチのある画面がアプリの全画面表示になっている間(メニューバーが隠れている間)は、"
              + "ノッチも一緒に隠れます。",
            "While an app is full screen on the notch screen (while the menu bar is hidden), "
              + "the notch hides with it."
          )
        )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      Section(L("閉じているとき", "When closed")) {
        Field(
          title: L("左の張り出し", "Left extension"),
          value: binding(\.leadingExtension),
          range: limits.sideExtension
        )
        Field(
          title: L("右の張り出し", "Right extension"),
          value: binding(\.trailingExtension),
          range: limits.sideExtension
        )
        Field(
          title: L("高さの追加", "Extra height"),
          value: binding(\.closedHeightIncrease),
          range: limits.closedHeightIncrease
        )
        Field(
          title: L("下の角", "Bottom corners"),
          value: binding(\.closedBottomCornerRadius),
          range: limits.cornerRadius
        )
      }

      Section(L("展開したとき", "When expanded")) {
        Field(title: L("幅", "Width"), value: binding(\.expandedWidth), range: limits.expandedWidth)
        Field(
          title: L("高さ", "Height"),
          value: binding(\.expandedHeight),
          range: limits.expandedHeight
        )
        Field(
          title: L("下の角", "Bottom corners"),
          value: binding(\.expandedBottomCornerRadius),
          range: limits.cornerRadius
        )
      }

      Section(L("共通", "Common")) {
        Field(
          title: L("上の角", "Top corners"),
          value: binding(\.topCornerRadius),
          range: limits.cornerRadius
        )
      }

      Section {
        HStack {
          Spacer()
          Button(L("既定へ戻す", "Reset to Defaults")) { store.reset() }
        }
      }
    }
    .formStyle(.grouped)
  }

  private func binding(_ path: WritableKeyPath<NotchAppearance, CGFloat>) -> Binding<Double> {
    Binding(
      get: { Double(store.appearance[keyPath: path]) },
      set: { store.appearance[keyPath: path] = CGFloat($0) }
    )
  }
}

private struct Field: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<CGFloat>

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 10) {
        Slider(value: $value, in: Double(range.lowerBound)...Double(range.upperBound))
        Text("\(Int(value.rounded()))")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 34, alignment: .trailing)
      }
    }
  }
}
