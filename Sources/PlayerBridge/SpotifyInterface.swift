import ScriptingBridge
import ScriptingBridgeGlue

/// ScriptingBridge synthesises these classes at runtime, so they are declared as
/// `@objc` protocols rather than generated `@interface` classes. A generated class
/// declaration has no symbol to link against.
@objc public protocol SpotifyTrack: NSObjectProtocol {
  @objc optional var name: String { get }
  @objc optional var artist: String { get }
  @objc optional var album: String { get }
  @objc optional var duration: Int { get }
  @objc optional var artworkUrl: String { get }
}

@objc public protocol SpotifyPlayer: NSObjectProtocol {
  @objc optional var currentTrack: SpotifyTrack { get }
  @objc optional var playerState: SpotifyPlayerStateValue { get }
  @objc optional var playerPosition: Double { get }
  @objc optional func playpause()
  @objc optional func nextTrack()
  @objc optional func previousTrack()
}

extension SBApplication: SpotifyPlayer {}
