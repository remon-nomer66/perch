// swift-tools-version: 6.2

import Foundation
import PackageDescription

// CLAUDE.md files are per-directory agent notes: gitignored, so a clean clone has
// none, while a working copy may hold one in any target directory. A fixed `exclude`
// warns on clean clones (missing file) and omitting it warns locally (unhandled
// file), so each target excludes the file only where it actually exists.
func agentNotes(_ directory: String) -> [String] {
  let path = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(directory)
    .appendingPathComponent("CLAUDE.md")
    .path
  return FileManager.default.fileExists(atPath: path) ? ["CLAUDE.md"] : []
}

let package = Package(
  name: "Perch",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "TandemCore", targets: ["TandemCore"]),
    .library(name: "BoseCore", targets: ["BoseCore"]),
    .library(name: "BosePanel", targets: ["BosePanel"]),
    .library(name: "DeviceContract", targets: ["DeviceContract"]),
    .executable(name: "Perch", targets: ["Perch"]),
    .executable(name: "perch-probe", targets: ["PerchProbe"]),
    .executable(name: "bose-probe", targets: ["BoseProbe"]),
    .executable(name: "bose-panel-preview", targets: ["BosePanelPreview"]),
  ],
  targets: [
    // Brand-neutral vocabulary shared by every headset. Pure value types, no
    // dependencies — the seam Sony and Bose adapters project onto.
    .target(
      name: "DeviceContract",
      exclude: agentNotes("Sources/DeviceContract")
    ),
    .target(
      name: "TandemCore",
      exclude: agentNotes("Sources/TandemCore")
    ),
    // Bose BMAP protocol layer. Pure value types, no dependencies — the Bose
    // counterpart to TandemCore, testable without hardware.
    .target(
      name: "BoseCore",
      exclude: agentNotes("Sources/BoseCore")
    ),
    // Bose BMAP session layer: transport-abstracted request model over BoseCore.
    // No IOBluetooth / CoreBluetooth yet — the real transports arrive in stage 5 and
    // will conform to `BmapChannel`; today only the protocol and its mock exist, so the
    // whole layer builds and tests without hardware.
    .target(
      name: "BoseSession",
      dependencies: ["BoseCore"],
      exclude: agentNotes("Sources/BoseSession")
    ),
    // Bose's own expanded panel UI: SwiftUI pages shaped to the Ultra 2 (continuous CNC,
    // independent ANC/wind, three-band EQ, audio modes, spatial, sidetone), plus the
    // view-model that projects a session snapshot onto panel state and turns gestures into
    // BoseSession commands. Deliberately not shared with Sony's panel (see
    // docs/bose-device-contract.md). No hardware — renders from synthetic state.
    .target(
      name: "BosePanel",
      dependencies: ["BoseCore", "BoseSession", "DeviceContract"],
      exclude: agentNotes("Sources/BosePanel")
    ),
    // Hardware-free tool that renders the Bose panel to PNG from frozen-spec fixture
    // values, for reviewing the layout without a device or the app running.
    .executableTarget(
      name: "BosePanelPreview",
      dependencies: ["BosePanel", "BoseCore", "DeviceContract"],
      exclude: agentNotes("Sources/BosePanelPreview")
    ),
    .target(
      name: "TandemSession",
      dependencies: ["TandemCore"],
      exclude: agentNotes("Sources/TandemSession"),
      linkerSettings: [
        .linkedFramework("IOBluetooth")
      ]
    ),
    // Bose's real RFCOMM transport (stage 5): the IOBluetooth host that conforms an
    // opened SPP channel to `BmapChannel`. Deliberately separate from TandemSession —
    // Sony and Bose share no transport code — so IOBluetooth is linked here too.
    .target(
      name: "BoseTransport",
      dependencies: ["BoseCore", "BoseSession"],
      exclude: agentNotes("Sources/BoseTransport"),
      linkerSettings: [
        .linkedFramework("IOBluetooth")
      ]
    ),
    .target(
      name: "NotchKit",
      exclude: agentNotes("Sources/NotchKit")
    ),
    .target(
      name: "ScriptingBridgeGlue",
      exclude: agentNotes("Sources/ScriptingBridgeGlue")
    ),
    .target(
      name: "PlayerBridge",
      dependencies: ["ScriptingBridgeGlue"],
      exclude: agentNotes("Sources/PlayerBridge"),
      linkerSettings: [
        .linkedFramework("ScriptingBridge")
      ]
    ),
    .executableTarget(
      name: "Perch",
      dependencies: ["TandemCore", "TandemSession", "NotchKit", "PlayerBridge"],
      exclude: agentNotes("Sources/Perch"),
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "PerchProbe",
      dependencies: ["TandemCore", "TandemSession"],
      exclude: agentNotes("Sources/PerchProbe")
    ),
    // Hardware疎通 probe for the Bose BMAP transport: opens a real channel and reads
    // identity/battery/NC read-only, for verifying stage 5 before wiring the full UI.
    .executableTarget(
      name: "BoseProbe",
      dependencies: ["BoseCore", "BoseSession", "BoseTransport"],
      exclude: agentNotes("Sources/BoseProbe")
    ),
    .testTarget(
      name: "DeviceContractTests",
      dependencies: ["DeviceContract"],
      exclude: agentNotes("Tests/DeviceContractTests")
    ),
    .testTarget(
      name: "TandemCoreTests",
      dependencies: ["TandemCore"],
      exclude: agentNotes("Tests/TandemCoreTests")
    ),
    .testTarget(
      name: "BoseCoreTests",
      dependencies: ["BoseCore"],
      exclude: agentNotes("Tests/BoseCoreTests")
    ),
    .testTarget(
      name: "BoseSessionTests",
      dependencies: ["BoseSession"],
      exclude: agentNotes("Tests/BoseSessionTests")
    ),
    .testTarget(
      name: "BosePanelTests",
      dependencies: ["BosePanel"],
      exclude: agentNotes("Tests/BosePanelTests")
    ),
    .testTarget(
      name: "TandemSessionTests",
      dependencies: ["TandemSession"],
      exclude: agentNotes("Tests/TandemSessionTests")
    ),
    .testTarget(
      name: "NotchKitTests",
      dependencies: ["NotchKit"],
      exclude: agentNotes("Tests/NotchKitTests")
    ),
    .testTarget(
      name: "PlayerBridgeTests",
      dependencies: ["PlayerBridge"],
      exclude: agentNotes("Tests/PlayerBridgeTests")
    ),
    .testTarget(
      name: "PerchTests",
      dependencies: ["Perch"],
      exclude: agentNotes("Tests/PerchTests")
    ),
  ]
)
