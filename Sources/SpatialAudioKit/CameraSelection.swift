/// Which camera head tracking uses, decided from the list alone.
///
/// Pure on purpose: the connected cameras, the saved choice and the camera already
/// running go in, one camera comes out. Everything that reacts to a camera coming or
/// going asks this same question, so a launch, a reconnect and an unplug cannot
/// disagree about where tracking should be looking.
public enum CameraSelection {
  /// The camera to use now.
  ///
  /// 1. The one the user picked, whenever it is connected — so a camera that comes
  ///    back is used again without anyone re-picking it.
  /// 2. Otherwise the one already running, so plugging or unplugging some other
  ///    camera never yanks tracking (and its calibration) away mid-session.
  /// 3. Otherwise the built-in camera, the one every portable Mac has and the one
  ///    tracking always used before cameras could be chosen.
  /// 4. Otherwise the first in the list (see `ordered`), so a Mac without a camera of
  ///    its own still tracks with whatever is attached.
  ///
  /// The pick is never cleared here: while it is missing, the fallback runs on
  /// borrowed time.
  public static func choose(
    from available: [CameraDevice],
    preferredID: String?,
    currentID: String?
  ) -> CameraDevice? {
    let lookup = { (id: String?) in id.flatMap { id in available.first { $0.id == id } } }
    return lookup(preferredID)
      ?? lookup(currentID)
      ?? available.first { $0.kind == .builtIn }
      ?? available.first
  }

  /// The order cameras are listed and fallen back to: built-in, then external, then
  /// Continuity Camera. Within a kind the discovery order stands — the system's own
  /// order is the least surprising tie-break, and sorting by name would reshuffle the
  /// menu whenever a device is renamed.
  public static func ordered(_ cameras: [CameraDevice]) -> [CameraDevice] {
    cameras.enumerated()
      .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
      .map(\.element)
  }

  /// A fresh enumeration, corrected by the device a connect/disconnect notification
  /// named. The notification is the authority on that one device: discovery run in
  /// the same instant can still list a camera that has just gone, or miss one that has
  /// just arrived, and acting on the stale list would keep tracking on a dead camera.
  public static func reconcile(
    _ enumerated: [CameraDevice],
    arrived: CameraDevice?,
    departedID: String?
  ) -> [CameraDevice] {
    let remaining = enumerated.filter { $0.id != departedID }
    let missing = arrived.flatMap { camera in
      remaining.contains { $0.id == camera.id } || camera.id == departedID ? nil : camera
    }
    return ordered(remaining + (missing.map { [$0] } ?? []))
  }
}
