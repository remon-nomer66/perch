import NotchKit
import Testing

@testable import Perch

private func panel(
  status: DeviceSummary.Status = .ready,
  name: String? = "Headset",
  battery: BatteryLayout = .single(80),
  announcing: Bool = false
) -> PanelModel {
  var model = PanelModel()
  model.summary.status = status
  model.summary.modelName = name
  model.battery = battery
  model.announcesArrival = announcing
  return model
}

// MARK: - Content

@Test("The bar has content only with a controllable device that has a name or a charge")
func barContent() {
  #expect(panel().hasContent)
  #expect(panel(name: nil).hasContent)
  #expect(panel(battery: .unknown).hasContent)
  #expect(!panel(name: nil, battery: .unknown).hasContent)
  #expect(!panel(status: .connecting).hasContent)
  #expect(!PanelModel().hasContent)
}

// MARK: - Widening

@Test(
  "Nothing to carry never widens the bar",
  arguments: [NotchPresenter.Presentation.closed, .popping, .opened]
)
func emptyBarNeverWidens(presentation: NotchPresenter.Presentation) {
  let empty = panel(status: .connecting, announcing: true)
  for displayMode in NotchDisplayMode.allCases {
    for isVirtual in [false, true] {
      #expect(
        !NotchBarVisibility.isExtended(
          model: empty, isVirtual: isVirtual, displayMode: displayMode,
          presentation: presentation
        )
      )
    }
  }
}

@Test("Always shown keeps a real notch's bar widened, pointer or not")
func alwaysShownWidens() {
  #expect(
    NotchBarVisibility.isExtended(
      model: panel(), isVirtual: false, displayMode: .always, presentation: .closed
    )
  )
}

@Test("Show on hover widens only while looked at")
func quietModeWidensWhileLookedAt() {
  let model = panel()
  #expect(
    !NotchBarVisibility.isExtended(
      model: model, isVirtual: false, displayMode: .onHover, presentation: .closed
    )
  )
  #expect(
    NotchBarVisibility.isExtended(
      model: model, isVirtual: false, displayMode: .onHover, presentation: .popping
    )
  )
}

@Test("The arrival announcement widens a quiet bar the pointer is not on")
func announcementWidensQuietBar() {
  // The view drew the announced bar while the hover target had shrunk to the bare
  // cutout, so the widened bar on screen ignored the pointer for those seconds.
  #expect(
    NotchBarVisibility.isExtended(
      model: panel(announcing: true), isVirtual: false, displayMode: .onHover,
      presentation: .closed
    )
  )
}

@Test("A virtual notch is quiet whatever the display mode says")
func virtualNotchIsQuiet() {
  for displayMode in NotchDisplayMode.allCases {
    #expect(
      !NotchBarVisibility.isExtended(
        model: panel(), isVirtual: true, displayMode: displayMode, presentation: .closed
      )
    )
    #expect(
      NotchBarVisibility.isExtended(
        model: panel(announcing: true), isVirtual: true, displayMode: displayMode,
        presentation: .closed
      )
    )
    #expect(
      NotchBarVisibility.isExtended(
        model: panel(), isVirtual: true, displayMode: displayMode, presentation: .popping
      )
    )
  }
}
