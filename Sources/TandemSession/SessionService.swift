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
    let audioChanges = audio.changes
    let bluetoothChanges = bluetooth.changes
    let powerChanges = power.changes

    pumps = [
      Task { [weak self] in
        for await output in audioChanges { await self?.audioOutputChanged(output) }
      },
      Task { [weak self] in
        for await change in bluetoothChanges { await self?.bluetoothChanged(change) }
      },
      Task { [weak self] in
        for await change in powerChanges { await self?.powerChanged(change) }
      },
    ]

    audio.start()
    bluetooth.start()
    power.start()
  }

  public func stop() {
    pumps.forEach { $0.cancel() }
    pumps = []
    audio.stop()
    bluetooth.stop()
    power.stop()
  }

  // MARK: - Translation

  private func audioOutputChanged(_ output: AudioOutput) async {
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
