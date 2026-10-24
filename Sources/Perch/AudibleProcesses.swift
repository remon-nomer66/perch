import CoreAudio
import Foundation

/// Which processes are currently outputting audio, read from Core Audio's process
/// objects (macOS 14.4+). The artist rules use this before trusting a browser tab's
/// title: the title only proves what is being listened to while that browser actually
/// makes sound. The spatialiser uses it to tell a tap that lost capture from one that
/// simply hears silence.
enum AudibleProcesses {
  /// What one process object says about itself — as much as the questions here need.
  /// Both questions are about processes that are outputting, so the pid and bundle ID
  /// are read only for those.
  struct Snapshot: Equatable, Sendable {
    /// nil when it cannot be read.
    let pid: pid_t?
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
  /// nil when the process objects cannot be read — "unknown", not silence.
  static func isAnotherProcessOutputting() -> Bool? {
    let ownPID = getpid()
    return snapshots().map { anyOutputting($0, excluding: ownPID) }
  }

  static func bundleIDs(outputtingIn snapshots: [Snapshot]) -> Set<String> {
    Set(
      snapshots
        .filter(\.isRunningOutput)
        .compactMap(\.bundleID)
        .filter { !$0.isEmpty }
    )
  }

  /// A process whose pid cannot be read is not counted: it might be Perch itself, and
  /// counting Perch would make "others are playing" true for as long as it spatialises.
  static func anyOutputting(_ snapshots: [Snapshot], excluding pid: pid_t) -> Bool {
    snapshots.contains { snapshot in
      guard snapshot.isRunningOutput, let processID = snapshot.pid else { return false }
      return processID != pid
    }
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
        pid: outputting ? pid(process) : nil,
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
  private static func pid(_ process: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr, pid > 0
    else { return nil }
    return pid
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
