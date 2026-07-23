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
    .executable(name: "Perch", targets: ["Perch"]),
    .executable(name: "perch-probe", targets: ["PerchProbe"]),
  ],
  targets: [
    .target(
      name: "TandemCore",
      exclude: agentNotes("Sources/TandemCore")
    ),
    .target(
      name: "TandemSession",
      dependencies: ["TandemCore"],
      exclude: agentNotes("Sources/TandemSession"),
      linkerSettings: [
        .linkedFramework("IOBluetooth")
      ]
    ),
    .target(
      name: "NotchKit",
      exclude: agentNotes("Sources/NotchKit")
    ),
    .target(
      name: "SpatialAudioKit",
      exclude: agentNotes("Sources/SpatialAudioKit")
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
    .testTarget(
      name: "TandemCoreTests",
      dependencies: ["TandemCore"],
      exclude: agentNotes("Tests/TandemCoreTests")
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
      name: "SpatialAudioKitTests",
      dependencies: ["SpatialAudioKit"],
      exclude: agentNotes("Tests/SpatialAudioKitTests")
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
