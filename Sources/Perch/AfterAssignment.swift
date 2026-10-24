import Combine
import Foundation

extension Publisher where Failure == Never {
  /// Delivers each value once the assignment that announced it has finished.
  ///
  /// `@Published` publishes from the property's `willSet`. A subscriber that uses the
  /// value it is handed is fine; one that reads the property back — or calls into
  /// something that does, such as a controller holding a closure over the store —
  /// still finds the old value there. Hopping to the next turn of the main queue lets
  /// the assignment complete first. The main queue rather than the main run loop: it
  /// is drained in every run loop mode, so a change made while a menu or a drag is
  /// tracking is not held back until the tracking ends.
  func afterAssignment() -> Publishers.ReceiveOn<Self, DispatchQueue> {
    receive(on: DispatchQueue.main)
  }
}
