#import <Foundation/Foundation.h>

/// Player state constants declared by the scripting definitions of the supported
/// players. Only the constants live here; the interfaces are declared as Swift
/// `@objc` protocols instead, because ScriptingBridge synthesises those classes at
/// runtime and generated `@interface` declarations have no symbol to link against.

typedef NS_ENUM(unsigned int, SpotifyPlayerStateValue) {
  SpotifyPlayerStateStopped = 'kPSS',
  SpotifyPlayerStatePlaying = 'kPSP',
  SpotifyPlayerStatePaused = 'kPSp',
};

typedef NS_ENUM(unsigned int, MusicPlayerStateValue) {
  MusicPlayerStateStopped = 'kPSS',
  MusicPlayerStatePlaying = 'kPSP',
  MusicPlayerStatePaused = 'kPSp',
  MusicPlayerStateFastForwarding = 'kPSF',
  MusicPlayerStateRewinding = 'kPSR',
};
