import AVFoundation

/// One camera head tracking could look through, as a plain value.
///
/// The capture device itself never leaves the camera code: lists, choices and the UI
/// handle only this, so the selection policy is testable without hardware and nothing
/// holds an `AVCaptureDevice` past the moment it was enumerated.
public struct CameraDevice: Sendable, Hashable, Identifiable {
  /// What kind of camera it is. The order of the cases is the fallback order: a
  /// camera built into the Mac first, then one plugged into it, and an iPhone last,
  /// so a phone on the desk never wins over a camera the Mac actually has unless
  /// someone picks it.
  public enum Kind: Int, Sendable, Comparable {
    case builtIn
    case external
    case continuity

    /// The continuity flag decides before the device type does: without
    /// `NSCameraUseContinuityCameraDeviceType` in the Info.plist (a bare `swift run`,
    /// the test runner) an iPhone is reported as `.external`, and it is still a phone.
    /// Types that cannot follow a face — the downward-looking Desk View — are not
    /// cameras for this purpose at all.
    public init?(deviceType: AVCaptureDevice.DeviceType, isContinuityCamera: Bool) {
      if isContinuityCamera {
        self = .continuity
        return
      }
      switch deviceType {
      case .builtInWideAngleCamera: self = .builtIn
      case .external: self = .external
      case .continuityCamera: self = .continuity
      default: return nil
      }
    }

    public static func < (lhs: Kind, rhs: Kind) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  /// `AVCaptureDevice.uniqueID`: stable across reconnects and relaunches, which is
  /// what lets a saved choice find the same camera again.
  public let id: String
  /// The system's name for it, for display only. It can carry a person's name (an
  /// iPhone is named after its owner), so it belongs on screen and never in a log.
  public let name: String
  public let kind: Kind

  public init(id: String, name: String, kind: Kind) {
    self.id = id
    self.name = name
    self.kind = kind
  }

  /// nil for anything that is not a usable video camera.
  public init?(device: AVCaptureDevice) {
    guard device.hasMediaType(.video),
      let kind = Kind(deviceType: device.deviceType, isContinuityCamera: device.isContinuityCamera)
    else { return nil }
    self.init(id: device.uniqueID, name: device.localizedName, kind: kind)
  }

  /// What discovery asks for. `.external` covers USB/Thunderbolt webcams and virtual
  /// cameras on macOS 14; `.continuityCamera` only yields phones when the Info.plist
  /// opts in, and is harmless when it does not (they then arrive as `.external`).
  public static let discoverableTypes: [AVCaptureDevice.DeviceType] = [
    .builtInWideAngleCamera, .external, .continuityCamera,
  ]
}
