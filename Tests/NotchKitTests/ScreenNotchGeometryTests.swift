import CoreGraphics
import Testing

@testable import NotchKit

/// Values shaped like a 14-inch built-in display.
private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

@Test func theNotchIsTheGapBetweenTheUnobstructedCorners() {
  let geometry = ScreenNotchGeometry.resolve(
    screenFrame: builtIn,
    safeAreaTop: 32,
    leftArea: CGRect(x: 0, y: 950, width: 620, height: 32),
    rightArea: CGRect(x: 892, y: 950, width: 620, height: 32)
  )

  #expect(geometry?.rect == CGRect(x: 620, y: 950, width: 272, height: 32))
}

@Test func aScreenWhoseOriginIsNotZeroStillPlacesTheNotchCorrectly() {
  // An external display to the left pushes the built-in screen's origin negative.
  // Deriving the notch from widths rather than coordinates misplaces it here.
  let shifted = CGRect(x: -1512, y: 300, width: 1512, height: 982)
  let geometry = ScreenNotchGeometry.resolve(
    screenFrame: shifted,
    safeAreaTop: 32,
    leftArea: CGRect(x: -1512, y: 1250, width: 620, height: 32),
    rightArea: CGRect(x: -620, y: 1250, width: 620, height: 32)
  )

  #expect(geometry?.rect == CGRect(x: -892, y: 1250, width: 272, height: 32))
}

@Test func asymmetricCornersAreHandled() {
  // The two areas need not be equal; the menu bar clock and notch are not centred
  // relative to each other on every configuration.
  let geometry = ScreenNotchGeometry.resolve(
    screenFrame: builtIn,
    safeAreaTop: 32,
    leftArea: CGRect(x: 0, y: 950, width: 500, height: 32),
    rightArea: CGRect(x: 900, y: 950, width: 612, height: 32)
  )

  #expect(geometry?.rect == CGRect(x: 500, y: 950, width: 400, height: 32))
}

@Test func aScreenWithoutANotchYieldsNothing() {
  let cases: [(CGFloat, CGRect?, CGRect?, String)] = [
    (0, CGRect(x: 0, y: 950, width: 620, height: 32), CGRect(x: 892, y: 950, width: 620, height: 32), "no safe area"),
    (32, nil, CGRect(x: 892, y: 950, width: 620, height: 32), "no left area"),
    (32, CGRect(x: 0, y: 950, width: 620, height: 32), nil, "no right area"),
    (32, nil, nil, "neither area"),
  ]

  for (safeArea, left, right, label) in cases {
    let geometry = ScreenNotchGeometry.resolve(
      screenFrame: builtIn,
      safeAreaTop: safeArea,
      leftArea: left,
      rightArea: right
    )
    #expect(geometry == nil, "\(label) produced a notch")
  }
}

@Test func overlappingCornersYieldNothingRatherThanAnInvertedRectangle() {
  // Contradictory inputs must not produce a rectangle that swallows menu bar clicks.
  let geometry = ScreenNotchGeometry.resolve(
    screenFrame: builtIn,
    safeAreaTop: 32,
    leftArea: CGRect(x: 0, y: 950, width: 900, height: 32),
    rightArea: CGRect(x: 600, y: 950, width: 912, height: 32)
  )

  #expect(geometry == nil)
}

@Test func aRectangleThatEscapesTheScreenIsRejected() {
  let geometry = ScreenNotchGeometry.resolve(
    screenFrame: builtIn,
    safeAreaTop: 32,
    leftArea: CGRect(x: 0, y: 950, width: 620, height: 32),
    rightArea: CGRect(x: 2000, y: 950, width: 620, height: 32)
  )

  #expect(geometry == nil)
}
