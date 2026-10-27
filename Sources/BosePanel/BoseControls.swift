import DeviceContract
import SwiftUI

// The small building blocks the Bose pages are made of. They are drawn to match the Sony
// panel's visual language — 10 pt tile text, corner radius 6, white-on-black at the same
// opacities, the same blue switch — so the two brands' panels feel like one app even
// though their pages are entirely separate. The Sony versions are `private` to its file,
// so these are fresh copies rather than shared code.

/// A page's quiet title, top-left of every sheet.
struct BosePageTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.white.opacity(0.45))
  }
}

/// The line a page shows when the device declares no such feature — never an empty or
/// dead control.
struct BoseNotDeclared: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10))
      .foregroundStyle(.white.opacity(0.4))
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A selectable tile: white-filled when chosen, faint when not. Matches the Sony segment
/// button so mode and spatial pickers read the same across brands.
struct BoseSegmentButton: View {
  let title: String
  let isSelected: Bool
  var fixedWidth = true
  var compact = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 3 : 5)
        .frame(maxWidth: fixedWidth ? .infinity : nil)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
        )
    }
    .buttonStyle(.plain)
  }
}

/// A switch drawn with its own colours: unmistakably blue when on. The stock switch takes
/// its tint from the window's key state, and the notch panel never becomes key, so the
/// stock control renders on and off almost identically there.
struct BosePanelSwitchStyle: ToggleStyle {
  var width: CGFloat = 30

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 6) {
        configuration.label
        Spacer(minLength: 0)
        Capsule()
          .fill(configuration.isOn ? Color.blue : Color.white.opacity(0.25))
          .frame(width: width, height: width * 0.58)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle().fill(.white).padding(1.5)
          }
          .animation(.easeOut(duration: 0.15), value: configuration.isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A labelled switch row, matching the Sony switch rows.
struct BoseSwitchRow: View {
  let title: String
  let isOn: Bool
  let set: (Bool) -> Void

  var body: some View {
    Toggle(title, isOn: Binding(get: { isOn }, set: { set($0) }))
      .toggleStyle(BosePanelSwitchStyle(width: 30))
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.85))
  }
}

/// A horizontal slider legible on the black panel, driven directly by a drag so the value
/// follows the pointer and reports its final position on release. The same geometry the
/// Sony level slider uses.
struct BoseLevelSlider: View {
  let value: Int
  let range: ClosedRange<Int>
  let onChange: (Int, Bool) -> Void

  private static let knob: CGFloat = 12

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let span = max(range.upperBound - range.lowerBound, 1)
      let fraction = Double(value - range.lowerBound) / Double(span)
      let knob = Self.knob

      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.15)).frame(height: 4)
        Capsule()
          .fill(.white.opacity(0.85))
          .frame(width: knob / 2 + CGFloat(fraction) * (width - knob), height: 4)
        Circle()
          .fill(.white)
          .frame(width: knob, height: knob)
          .offset(x: CGFloat(fraction) * (width - knob))
      }
      .frame(height: knob)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { report($0.location.x, width: width, isFinal: false) }
          .onEnded { report($0.location.x, width: width, isFinal: true) }
      )
    }
  }

  private func report(_ x: CGFloat, width: CGFloat, isFinal: Bool) {
    let span = range.upperBound - range.lowerBound
    let travel = max(width - Self.knob, 1)
    let fraction = min(max((x - Self.knob / 2) / travel, 0), 1)
    let level = range.lowerBound + Int((Double(span) * Double(fraction)).rounded())
    onChange(level, isFinal)
  }
}

/// A vertical EQ band slider: one thin track, a knob riding at the value, a faint flat
/// tick so zero is findable. Top is boost, bottom is cut. The same shape the Sony EQ uses.
struct BoseBandSlider: View {
  let value: Int
  let range: ClosedRange<Int>
  let flat: Int
  let onChange: ((Int, Bool) -> Void)?

  private static let height: CGFloat = 58
  private static let knob: CGFloat = 11

  var body: some View {
    let span = max(range.upperBound - range.lowerBound, 1)
    let fraction = Double(value - range.lowerBound) / Double(span)
    let travel = Self.height - Self.knob
    let flatFraction = Double(flat - range.lowerBound) / Double(span)

    ZStack(alignment: .top) {
      Capsule().fill(.white.opacity(0.12)).frame(width: 3)
      Rectangle()
        .fill(.white.opacity(0.3))
        .frame(width: 9, height: 1)
        .offset(y: Self.knob / 2 + (1 - flatFraction) * travel)
      Circle()
        .fill(.white.opacity(onChange == nil ? 0.45 : 0.95))
        .frame(width: Self.knob, height: Self.knob)
        .offset(y: (1 - fraction) * travel)
    }
    .frame(width: 20, height: Self.height)
    .contentShape(Rectangle())
    .gesture(drag)
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { report($0.location.y, isFinal: false) }
      .onEnded { report($0.location.y, isFinal: true) }
  }

  private func report(_ y: CGFloat, isFinal: Bool) {
    guard let onChange else { return }
    let travel = Self.height - Self.knob
    let fraction = 1 - min(max((y - Self.knob / 2) / travel, 0), 1)
    let span = range.upperBound - range.lowerBound
    let newValue = range.lowerBound + Int((Double(span) * Double(fraction)).rounded())
    onChange(min(max(newValue, range.lowerBound), range.upperBound), isFinal)
  }
}

/// The page-position dots, matching the Sony indicator exactly.
struct BosePageIndicator: View {
  let count: Int
  let index: Int

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<count, id: \.self) { position in
        Circle()
          .fill(.white.opacity(position == index ? 0.85 : 0.22))
          .frame(width: 4, height: 4)
      }
    }
    .animation(.easeOut(duration: 0.15), value: index)
  }
}

/// The header charge readout, mirroring the closed bar's shape from the shared reading.
struct BoseBatteryReadout: View {
  let battery: BatteryReading

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(battery.cells.enumerated()), id: \.offset) { _, cell in
        HStack(spacing: 3) {
          if let label = Self.label(for: cell.enclosure) {
            Text(label)
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(.white.opacity(0.5))
          } else {
            Image(systemName: "battery.100")
              .font(.system(size: 9))
              .foregroundStyle(.white.opacity(0.5))
          }
          Text(cell.percent.map { "\($0)" } ?? "—")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle((cell.percent ?? 100) < 20 ? Color.red : Color.white.opacity(0.9))
        }
      }
    }
  }

  private static func label(for enclosure: BatteryReading.Enclosure) -> String? {
    switch enclosure {
    case .single: nil
    case .left: "L"
    case .right: "R"
    case .caseEnclosure: L("ケース", "Case")
    case .other(let index): "\(index + 1)"
    }
  }
}
