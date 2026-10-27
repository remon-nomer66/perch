import Foundation
import TandemCore

/// Wires the system observers to the coordinator.
///
/// The observers speak about the machine; the policy speaks about one device. This is
/// where the two are reconciled, including the decision that an output we cannot
/// identify is not a device we may control.
public actor SessionService {
  private let coordinator: SessionCoordinator
  private let audio: any AudioOutputObserving
  private let bluetooth: any BluetoothConnectionObserving
  private let power: any PowerObserving

  private var pumps: [Task<Void, Never>] = []
  private var currentTarget: DeviceIdentity?
  private var isStarted = false
  private var isStopped = false
  private var stopTask: Task<Void, Never>?

  // The observers are protocol-typed so the translation below — which output
  // becomes which session event — can be tested without Core Audio, IOBluetooth,
  // or the workspace behind it.
  public init(
    coordinator: SessionCoordinator,
    audio: any AudioOutputObserving = AudioOutputObserver(),
    bluetooth: any BluetoothConnectionObserving = BluetoothConnectionObserver(),
    power: any PowerObserving = PowerObserver()
  ) {
    self.coordinator = coordinator
    self.audio = audio
    self.bluetooth = bluetooth
    self.power = power
  }

  public static func live(
    policy: SessionPolicy = SessionPolicy(),
    timeouts: SessionCoordinator.Timeouts = .init()
  ) -> SessionService {
    SessionService(
      coordinator: SessionCoordinator(
        policy: policy,
        opener: RFCOMMChannelOpener(),
        verifier: DeviceVerification(),
        timeouts: timeouts
      )
    )
  }

  public var session: SessionCoordinator { coordinator }

  public func start() async {
    guard !isStarted, !isStopped else { return }
    isStarted = true
    let audioChanges = audio.changes
    let bluetoothChanges = bluetooth.changes
    let powerChanges = power.changes

    pumps = [
      Task { [weak self] in
        for await output in audioChanges {
          guard !Task.isCancelled else { return }
          await self?.audioOutputChanged(output)
        }
      },
      Task { [weak self] in
        for await change in bluetoothChanges {
          guard !Task.isCancelled else { return }
          await self?.bluetoothChanged(change)
        }
      },
      Task { [weak self] in
        for await change in powerChanges {
          guard !Task.isCancelled else { return }
          await self?.powerChanged(change)
        }
      },
    ]

    audio.start()
    bluetooth.start()
    power.start()
  }

  /// Terminal for this instance: cancelling an observer stream also ends that
  /// stream. Create a new service to start another observation lifetime.
  public func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    isStopped = true
    currentTarget = nil
    let stoppingPumps = pumps
    stoppingPumps.forEach { $0.cancel() }
    pumps = []
    let stopping = Task {
      // A pump can already have sent an event to the coordinator. Drain it before
      // terminal shutdown so that event cannot race the final release.
      for pump in stoppingPumps { await pump.value }
      audio.stop()
      bluetooth.stop()
      power.stop()
      await coordinator.shutdown()
    }
    stopTask = stopping
    await stopping.value
  }

  // MARK: - Translation

  private func audioOutputChanged(_ output: AudioOutput) async {
    guard !isStopped else { return }
    switch output {
    case .identified(let device):
      currentTarget = device
      await coordinator.handle(.defaultOutputChanged(device))

    case .unidentifiedBluetooth, .other:
      // An output we cannot pin to a paired device is treated as no target. Guessing
      // would risk opening a control session on the wrong headphones.
      currentTarget = nil
      await coordinator.handle(.defaultOutputChanged(nil))
    }
  }

  private func bluetoothChanged(_ change: BluetoothConnectionObserver.Change) async {
    guard !isStopped else { return }
    switch change {
    case .disconnected(let device) where device == currentTarget:
      await coordinator.handle(.bluetoothDisconnected)
    case .disconnected, .connected:
      // A device becoming reachable is not a reason to take its control session.
      // That decision belongs to the audio output.
      break
    }
  }

  private func powerChanged(_ change: PowerObserver.Change) async {
    guard !isStopped else { return }
    switch change {
    case .willSleep:
      await coordinator.handle(.willSleep)
    case .didWake:
      // Ask the audio system rather than trusting what was true before sleeping.
      let output = audio.current()
      if case .identified(let device) = output {
        currentTarget = device
        await coordinator.handle(.didWake(device))
      } else {
        currentTarget = nil
        await coordinator.handle(.didWake(nil))
      }
    }
  }
}
