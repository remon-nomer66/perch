import Foundation

extension DeviceReadings {
  /// The readings something other than the poll can change: a write's read-back, or
  /// a notification the device sends when it is changed by hand.
  enum Setting: CaseIterable, Hashable, Sendable {
    case equalizer
    case noiseControl
    case listeningMode
    case speakToChat
    case sidetone
  }

  /// A poll cycle's result with `settings` taken from `current` instead.
  ///
  /// A cycle reads each value once, early or late, and stores them all together at
  /// the end. A setting changed in the meantime is newer than what the cycle read,
  /// so storing the cycle whole would put the old value back until the next cycle.
  func keeping(_ settings: Set<Setting>, from current: DeviceReadings) -> DeviceReadings {
    var merged = self
    for setting in settings {
      switch setting {
      case .equalizer: merged.equalizer = current.equalizer
      case .noiseControl: merged.noiseControl = current.noiseControl
      case .listeningMode: merged.listeningMode = current.listeningMode
      case .speakToChat: merged.speakToChat = current.speakToChat
      case .sidetone: merged.sidetone = current.sidetone
      }
    }
    return merged
  }
}

/// Counts how often each setting was changed outside the poll.
///
/// A cycle notes the counts when it starts and compares when it stores, which tells
/// it what changed underneath it without anything having to reset the counts.
struct SettingRevisions: Equatable, Sendable {
  private let counts: [DeviceReadings.Setting: UInt64]

  init() {
    counts = [:]
  }

  private init(counts: [DeviceReadings.Setting: UInt64]) {
    self.counts = counts
  }

  func bumping(_ setting: DeviceReadings.Setting) -> SettingRevisions {
    var next = counts
    next[setting, default: 0] &+= 1
    return SettingRevisions(counts: next)
  }

  func settingsChanged(since earlier: SettingRevisions) -> Set<DeviceReadings.Setting> {
    Set(DeviceReadings.Setting.allCases.filter { counts[$0] != earlier.counts[$0] })
  }
}
