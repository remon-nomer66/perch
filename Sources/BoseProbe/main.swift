import BoseCore
import BoseSession
import BoseTransport
import CoreAudio
import Foundation
import IOBluetooth

// Read-only疎通確認 for the Bose BMAP RFCOMM transport (段階5). Opens the control
// channel on a connected Bose device, runs the connect handshake, then GETs identity,
// firmware, battery and the noise-cancellation level and prints them. Nothing is
// written to the device, and the device address is never printed.
//
// Run under tools/control-lock.sh, with the phone's Bose app disconnected (the control
// channel is single-holder). If a terminal-launched process is refused by bluetoothd
// (macOS 26 has been reported to only allow RFCOMM from LaunchServices-launched apps),
// that is itself the answer to one of the probe questions — see docs/rfcomm-transport-notes.md.

// When launched as a `.app` via LaunchServices (the only way classic-Bluetooth SDP is
// permitted on macOS 26), there is no terminal to print to, so `--out <path>` redirects
// all output to a file the launcher can read back afterwards.
var probeArguments = Array(CommandLine.arguments.dropFirst())
if let outIndex = probeArguments.firstIndex(of: "--out"), outIndex + 1 < probeArguments.count {
  let path = probeArguments[outIndex + 1]
  freopen(path, "w", stdout)
  freopen(path, "a", stderr)
  probeArguments.removeSubrange(outIndex...(outIndex + 1))
}

// Unbuffer stdout so progress shows even when redirected to a file (Swift's `print`
// is otherwise block-buffered to a non-TTY, so a hang looks like no output at all).
setbuf(stdout, nil)

let usageText = """
  usage: bose-probe [ultra2|qc35] [bluetooth-address]
         bose-probe diagnose
         both arguments optional; the model defaults to ultra2 and the device is
         auto-selected from the connected Bose device when no address is given.
         `diagnose` enumerates paired/connected devices and their BMAP SDP records
         without opening a channel (no address or name is ever printed).
  """

// Enumerate paired/connected devices and whether each advertises the BMAP control
// service, to tell an empty/permission-denied device list apart from a device whose
// SDP records simply do not match. Prints only counts and booleans — never an address
// or name (PII rule).
if probeArguments.first?.lowercased() == "diagnose" {
  let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
  print("paired devices     \(paired.count)")
  print("connected devices  \(paired.filter { $0.isConnected() }.count)")
  print("(addresses/names are never printed — devices are shown by index only)")

  // The CoreAudio default output — what the app's AudioOutputObserver actually sees.
  // Correlating its address to a BMAP device is the whole question for the app's gate.
  printAudioOutputCorrelation(paired: paired)

  for (index, device) in paired.enumerated() {
    let connected = device.isConnected()
    // Refresh SDP for connected devices (the ones we could actually open); an empty
    // cache is why a first getServiceRecord returns nil.
    let refresh = connected ? refreshSDPCache(device) : "skipped (not connected)"
    let marker = cachedServiceChannel(device, uuid: BmapServiceDiscovery.markerUUID)
    let spp = cachedServiceChannel(device, uuid: BmapServiceDiscovery.serialPortUUID)
    // Only surface devices that are connected or expose something relevant, to keep the
    // dump short across 16 paired devices.
    guard connected || marker.present || spp.present else { continue }
    print("--- device #\(index) (connected=\(connected)) ---")
    // OUI = the address's first three octets (the manufacturer block; identifies the
    // maker, not the user). Read from the address string only — never `device.name`,
    // which blocks on a synchronous remote name request for an uncached device.
    if let addr = device.addressString {
      let oui = addr.split(separator: "-").prefix(3).joined(separator: "-")
      print("  oui: \(oui)")
    }
    print("  classOfDevice: \(String(format: "0x%06X", device.classOfDevice))")
    print("  sdp refresh:  \(refresh)")
    let markerCh = marker.channel.map { "ch\($0)" } ?? "no-rfcomm"
    let sppCh = spp.channel.map { "ch\($0)" } ?? "no-rfcomm"
    print("  BMAP marker:  present=\(marker.present) \(marker.present ? markerCh : "")")
    print("  SPP (0x1101): present=\(spp.present) \(spp.present ? sppCh : "")")
    let services = device.services as? [IOBluetoothSDPServiceRecord] ?? []
    print("  service records: \(services.count)")
    for record in services {
      var channel: BluetoothRFCOMMChannelID = 0
      let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess && channel != 0
      let channelText = hasChannel ? "ch\(channel)" : "no-rfcomm"
      let classList = record.attributes?[1] as? IOBluetoothSDPDataElement
      let classes = sdpUUIDs(in: classList).joined(separator: ",")
      print("    [\(channelText)] classes: \(classes.isEmpty ? "—" : classes)")
    }
    print("  controlChannel: \(BmapServiceDiscovery.controlChannel(on: device).map(String.init) ?? "—")")
  }
  if paired.isEmpty {
    print("note: an empty list usually means this process lacks Bluetooth permission.")
  }
  exit(0)
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// Carries a non-Sendable IOBluetooth value into a worker thread's closure. Safe here
/// because the value is only used on that one thread.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// The first three address octets (the OUI / manufacturer block — identifies the maker,
/// never the user) parsed from a string that contains a Bluetooth address somewhere.
func ouiOf(_ string: String) -> String? {
  let octets = string.split(whereSeparator: { $0 == "-" || $0 == ":" })
    .map(String.init)
    .filter { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
  guard octets.count >= 3 else { return nil }
  return octets.prefix(3).map { $0.lowercased() }.joined(separator: "-")
}

/// Prints how the CoreAudio default output correlates to the paired/BMAP devices, so the
/// app's gate (audio output → which Bose control address) can be designed. Prints only
/// the manufacturer OUI and booleans — never the full address.
func printAudioOutputCorrelation(paired: [IOBluetoothDevice]) {
  print("--- audio output ---")
  var deviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var device = AudioObjectID(0)
  var size = UInt32(MemoryLayout<AudioObjectID>.size)
  guard
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &device
    ) == noErr, device != 0
  else {
    print("  (no default output device)")
    return
  }
  var transportAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyTransportType,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var transport = UInt32(0)
  var tsize = UInt32(MemoryLayout<UInt32>.size)
  _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &tsize, &transport)
  let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
  print("  transport: \(isBluetooth ? "bluetooth" : String(format: "0x%08X", transport))")

  var uidAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var usize = UInt32(MemoryLayout<CFString?>.size)
  var uidValue: Unmanaged<CFString>?
  let uidStatus = withUnsafeMutablePointer(to: &uidValue) { pointer in
    AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &usize, pointer)
  }
  guard uidStatus == noErr, let uidValue else {
    print("  (no device UID)")
    return
  }
  let uid = uidValue.takeRetainedValue() as String
  guard let oui = ouiOf(uid) else {
    print("  audio OUI: (address not found in UID)")
    return
  }
  print("  audio output OUI: \(oui)")
  // Does any BMAP-advertising paired device share this OUI?
  let bmapOUIs = paired
    .filter { BmapServiceDiscovery.advertisesBmap($0) }
    .compactMap { $0.addressString.flatMap(ouiOf) }
  print("  BMAP device OUIs: \(Set(bmapOUIs).sorted().joined(separator: ", "))")
  print("  audio OUI matches a BMAP device: \(bmapOUIs.contains(oui))")
  // Is the audio output address itself one of the paired devices, and does it advertise BMAP?
  if let match = paired.first(where: { $0.addressString.flatMap(ouiOf) == oui }) {
    print("  audio device advertises BMAP: \(BmapServiceDiscovery.advertisesBmap(match))")
  }
}

// Refreshes a device's cached SDP records synchronously. `getServiceRecord`/`services`
// read the per-process cache, which is empty until a query completes; `performSDPQuery`
// repopulates it. The query's completion is delivered to the run loop of the thread that
// called it, so it runs on a dedicated thread whose run loop is actually spinning —
// blocking the caller's thread instead (as a naive semaphore.wait would) deadlocks the
// callback and looks like a timeout. Non-async so it may block on the delegate callback.
func refreshSDPCache(_ device: IOBluetoothDevice) -> String {
  // @unchecked Sendable: all mutable state is touched only on the worker thread before
  // `finished` is signalled, and read on the caller only after `finished.wait()`, so the
  // semaphore is the happens-before edge that makes the hand-off safe.
  final class SDPWaiter: NSObject, IOBluetoothDeviceAsyncCallbacks, @unchecked Sendable {
    var isDone = false
    var started = false
    var status: IOReturn = kIOReturnSuccess
    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
      self.status = status
      isDone = true
    }
  }
  let waiter = SDPWaiter()
  let finished = DispatchSemaphore(value: 0)
  let unchecked = UncheckedSendableBox(device)
  let thread = Thread {
    let device = unchecked.value
    // A run loop with no sources returns immediately, so hold one open, as IOBluetooth's
    // own callback delivery requires a running loop on this thread.
    let port = Port()
    RunLoop.current.add(port, forMode: .default)
    // Establish the baseband first: a device connected only for audio may need an ACL
    // link before it answers SDP (rfcomm-transport-notes.md §5).
    if !device.isConnected() {
      _ = device.openConnection()
    }
    waiter.started = device.performSDPQuery(waiter) == kIOReturnSuccess
    if waiter.started {
      let deadline = Date().addingTimeInterval(8)
      // The callback fires on this same thread inside CFRunLoopRunInMode, so `isDone`
      // is read and written on one thread — no cross-thread race here.
      while !waiter.isDone, Date() < deadline {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.2, true)
      }
    }
    finished.signal()
  }
  thread.start()
  finished.wait()
  if !waiter.started { return "not started" }
  guard waiter.isDone else { return "timed out" }
  let statusHex = String(format: "0x%08X", UInt32(bitPattern: waiter.status))
  return "done (status \(statusHex))"
}

// Whether a device's cached SDP holds a record for `uuid`, and its RFCOMM channel if
// any. This is exactly the read path the transport uses (getServiceRecord), so it tells
// us what the real open would see.
func cachedServiceChannel(_ device: IOBluetoothDevice, uuid: UUID) -> (present: Bool, channel: BluetoothRFCOMMChannelID?) {
  var bytes = uuid.uuid
  let sdpUUID = withUnsafeBytes(of: &bytes) { buffer in
    IOBluetoothSDPUUID(bytes: buffer.baseAddress, length: buffer.count)
  }
  guard let record = device.getServiceRecord(for: sdpUUID) else { return (false, nil) }
  var channel: BluetoothRFCOMMChannelID = 0
  let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess && channel != 0
  return (true, hasChannel ? channel : nil)
}

// Extracts every UUID in a data element tree (a ServiceClassIDList is a sequence of
// UUIDs) as lowercase hex. Service-class UUIDs are protocol identifiers, not device PII.
func sdpUUIDs(in element: IOBluetoothSDPDataElement?) -> [String] {
  guard let element else { return [] }
  if let uuid = element.getUUIDValue() {
    // IOBluetoothSDPUUID is an NSData subclass holding the raw UUID bytes.
    let data = Data(referencing: uuid)
    return [data.map { String(format: "%02x", $0) }.joined()]
  }
  if let array = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
    return array.flatMap { sdpUUIDs(in: $0) }
  }
  return []
}

// Parse args in any order: a known model keyword picks the config, anything else is
// treated as an address.
var config: BoseDeviceConfig = .qcUltra2
var modelLabel = "ultra2 (QC Ultra 2 family)"
var address: String?
for arg in probeArguments {
  switch arg.lowercased() {
  case "ultra2", "ultra", "qcultra2":
    config = .qcUltra2
    modelLabel = "ultra2 (QC Ultra 2 family)"
  case "qc35", "qc35ii":
    config = .qc35
    modelLabel = "qc35 (QC35 family)"
  case "-h", "--help":
    print(usageText)
    exit(0)
  default:
    address = arg
  }
}

func hex(_ frame: BmapFrame) -> String {
  [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
}

// Opens, connects and reads one candidate device. Returns true when the device answered
// BMAP, so the caller can stop at the first that works. Every step is labelled so a
// failure shows exactly how far the link got.
func probe(address: String, config: BoseDeviceConfig) async -> Bool {
  let opened: OpenedBmapChannel
  do {
    opened = try await BmapRFCOMMChannelOpener().open(address: address)
  } catch {
    print("  open:    failed (\(error))")
    return false
  }
  print("  open:    ok")

  let session = await BoseSession.start(opened: opened, config: config)
  do {
    try await session.connect()
    print("  connect: ok")

    if config.supports(.deviceName) {
      let frame = try await session.request(try BmapProductInfo.deviceNameRequest())
      print("  name:    \(try BmapProductInfo.parseDeviceName(frame))")
    }
    if config.supports(.firmwareVersion) {
      let frame = try await session.request(try BmapProductInfo.firmwareRequest())
      print("  firmware:\(try BmapProductInfo.parseFirmware(frame))")
    }
    if config.supports(.battery) {
      let request = try BmapFrame(
        fblock: BmapFunctionAddress.battery.fblock,
        function: BmapFunctionAddress.battery.function,
        op: .get
      )
      let frame = try await session.request(request)
      let components = try BmapBattery.parse(frame, layout: config.batteryLayout)
      print("  battery: \(hex(frame))")
      for component in components {
        let id = component.componentId.map { String(format: "0x%02X", $0) } ?? "—"
        let remaining = component.minutesRemaining.map { "\($0)m" } ?? "—"
        print("    component \(id): \(component.percent)%  remaining \(remaining)")
      }
    }
    // NC level [1.5], read only: the raw payload lets the frozen-spec byte order
    // (byte0=numSteps, byte1=current) be checked against the real device.
    if config.supports(.noiseCancellationRead) {
      let frame = try await session.request(try BmapNoiseCancellationReader.readRequest())
      let reading = try BmapNoiseCancellationReader.parse(frame)
      print("  nc level:\(hex(frame)) → current \(reading.currentStep)/max \(reading.maximumStep)")
    }

    // Raw GET probe of block-31 (audio modes / live noise control) and [1.6]. Shows what
    // op and payload each function answers with — the app's [31.10] GET returns nothing,
    // so spatial/ANC/wind never populate. This reveals whether GET is answered at all, or
    // only STATUS/SETGET, and what block 31 exposes (modes).
    func rawGet(_ label: String, fblock: UInt8, function: UInt8, timeout: Duration = .seconds(2)) async {
      do {
        let req = try BmapFrame(fblock: fblock, function: function, op: .get)
        let frame = try await session.request(req, responseTimeout: timeout)
        print("  \(label) [\(fblock).\(function)] GET → op=\(frame.op) payload=\(hex(frame))")
      } catch {
        print("  \(label) [\(fblock).\(function)] GET → \(error)")
      }
    }
    func rawGetPayload(_ label: String, fblock: UInt8, function: UInt8, payload: [UInt8]) async {
      do {
        let req = try BmapFrame(fblock: fblock, function: function, op: .get, payload: Data(payload))
        let frame = try await session.request(req, responseTimeout: .seconds(2))
        print("  \(label) → op=\(frame.op) len=\(frame.payload.count) payload=\(hex(frame))")
      } catch {
        print("  \(label) → \(error)")
      }
    }
    print("  --- modes ---")
    await rawGet("  current[31.3]", fblock: 31, function: 3)
    await rawGet("  b31.2", fblock: 31, function: 2)
    // ModeConfig STATUS per mode index (0=Quiet 1=Aware 2=Immersion 3=Cinema 4=Home).
    for index in UInt8(0)...UInt8(6) {
      await rawGetPayload("  modeCfg[31.6] idx=\(index)", fblock: 31, function: 6, payload: [index])
    }

    await session.close()
    return true
  } catch {
    print("  read:    failed (\(error))")
    await session.close()
    return false
  }
}

print("model config    \(modelLabel)")

// Candidates: an explicit address if given, else every paired device advertising BMAP
// (connected first). Trying each disentangles a TWS earbud whose BMAP records live on a
// different address than the one currently carrying audio.
let candidates: [String]
if let address {
  candidates = [address]
} else {
  candidates = bmapDeviceAddresses()
}
if candidates.isEmpty {
  fail("no paired Bose (BMAP) device found in cached SDP. Run `bose-probe diagnose` first.")
}
print("candidates      \(candidates.count) (by index; addresses never printed)")

var connected = false
for (index, candidate) in candidates.enumerated() {
  print("--- candidate #\(index) ---")
  if await probe(address: candidate, config: config) {
    print("--- probe ok (candidate #\(index)) ---")
    connected = true
    break
  }
}
if !connected {
  fail("no candidate answered BMAP. See per-candidate failures above.")
}
