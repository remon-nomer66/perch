import CoreAudio
import Foundation
import SpatialAudioKit

/// Which processes are currently outputting audio, read from Core Audio's process
/// objects (macOS 14.4+). The artist rules use this before trusting a browser tab's
/// title: the title only proves what is being listened to while that browser actually
/// makes sound. The spatialiser uses it to tell a tap that lost capture from one that
/// simply hears silence.
enum AudibleProcesses {
  /// What one process object says about itself — as much as the questions here need.
  /// Both questions are about processes that are outputting, so the bundle ID is read
  /// only for those.
  struct Snapshot: Equatable, Sendable {
    /// The process object itself, straight from the list — always known, unlike the
    /// pid or bundle ID.
    let objectID: AudioObjectID
    let bundleID: String?
    let isRunningOutput: Bool
  }

  /// nil when the process objects cannot be read — older macOS or a Core Audio error —
  /// which the caller must treat as "unknown", not as silence.
  static func outputtingBundleIDs() -> Set<String>? {
    snapshots().map(bundleIDs(outputtingIn:))
  }

  /// Whether a process other than Perch is outputting audio. Perch itself is left out:
  /// while spatial audio runs, its own output is the spatialised copy of everyone else's.
  /// It is told apart by its process object, translated from its pid the same way the tap
  /// excludes it. nil when the process objects, or Perch's own, cannot be read —
  /// "unknown", not silence.
  static func isAnotherProcessOutputting() -> Bool? {
    guard #available(macOS 14.4, *), let ownObject = SystemAudioTap.currentProcessObjectID()
    else { return nil }
    return snapshots().map { anyOutputting($0, excluding: ownObject) }
  }

  static func bundleIDs(outputtingIn snapshots: [Snapshot]) -> Set<String> {
    Set(
      snapshots
        .filter(\.isRunningOutput)
        .compactMap(\.bundleID)
        .filter { !$0.isEmpty }
    )
  }

  static func anyOutputting(_ snapshots: [Snapshot], excluding ownObject: AudioObjectID) -> Bool {
    snapshots.contains { $0.isRunningOutput && $0.objectID != ownObject }
  }

  private static func snapshots() -> [Snapshot]? {
    guard #available(macOS 14.4, *) else { return nil }
    var listAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &size) == noErr,
      size > 0
    else { return nil }
    var processes = [AudioObjectID](
      repeating: AudioObjectID(), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &size, &processes) == noErr
    else { return nil }

    return processes.map { process in
      let outputting = isRunningOutput(process)
      return Snapshot(
        objectID: process,
        bundleID: outputting ? bundleID(process) : nil,
        isRunningOutput: outputting
      )
    }
  }

  @available(macOS 14.4, *)
  private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningOutput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else {
      return false
    }
    return running != 0
  }

  @available(macOS 14.4, *)
  private static func bundleID(_ process: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let bundle = value?.takeRetainedValue() else { return nil }
    return bundle as String
  }
}
