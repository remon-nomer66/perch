import CoreAudio
import Foundation

/// The bundle IDs of the processes currently outputting audio, read from Core Audio's
/// process objects (macOS 14.4+). The artist rules use this before trusting a browser
/// tab's title: the title only proves what is being listened to while that browser
/// actually makes sound.
enum AudibleProcesses {
  /// nil when the process objects cannot be read — older macOS or a Core Audio error —
  /// which the caller must treat as "unknown", not as silence.
  static func outputtingBundleIDs() -> Set<String>? {
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

    var outputting: Set<String> = []
    for process in processes where isRunningOutput(process) {
      if let bundle = bundleID(process), !bundle.isEmpty {
        outputting.insert(bundle)
      }
    }
    return outputting
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
