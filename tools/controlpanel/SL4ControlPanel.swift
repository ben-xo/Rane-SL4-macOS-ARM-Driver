// SL4ControlPanel.swift — "SL 4 Control Panel", a small app to see and set the Rane SL 4's state:
// connection, firmware and driver versions, the sample rate (chosen on the box), latency, the USB ports A
// and B, each of the four decks' analog thru, the input and output levels, and the output volume. It talks
// to the SL4Device HAL plug-in through CoreAudio, as sl4panel does:
//   'sl4s'  the driver's status (SL4StatusPacket, plugin/SL4Status.h)
//   'sl4h'  a 64-byte HID command to the box; reading it back returns the box's reply
//   'sl4q'  the box's unsolicited reports queued for this app (64 bytes each, oldest first)
//   'sl4m'  the peak level of each input and output channel since the last read
//   'sl4i'  the input safety offset setting, in microseconds (set with nothing streaming)
// and the device's standard output volumes (the master and each of the ten channels).
// The SL 4's LINE/PHONO switches are not reported to the computer, so the panel doesn't show them.
// Built by tools/controlpanel/build-app.sh (make controlpanel).

import AppKit
import CoreAudio
import IOKit
import SwiftUI

// MARK: - The driver, through CoreAudio

enum SL4Driver {
    static let deviceUID = "com.rane.sl4.hal.device"
    static let pluginBundleID = "io.github.pepeleedj.sl4device"
    static let driverBundlePath = "/Library/Audio/Plug-Ins/HAL/SL4Device.driver"

    static let vendorID = 0x1cc5
    /// The SL 4, and the same box under its alternate product ID (after HID 0x1a).
    static let productIDs = [0x000F, 0x0010]
    /// The newest SL 4 firmware Rane released: 1.02, the image in its 2.0.1f1 driver.
    static let latestFirmware = (major: 1, minor: 2)

    static let decks = 4
    /// Ten channels each way: decks 1-4 and Aux, in stereo pairs.
    static let channels = 10

    // HID commands. Every command and reply is one 64-byte report: [0] command, [1..4] tag (echoed in
    // the reply), [5...] arguments or results.
    static let reportLength = 64
    /// Hidi: [5] message length, [6...] MIDI bytes. Note On / Note Off of a deck's note switches its thru
    /// on (analog thru) / off (USB audio), channel 1.
    static let cmdHidi: UInt8 = 0x41
    static let midiNoteOff: UInt8 = 0x80
    static let midiNoteOn: UInt8 = 0x90
    static let noteThru: [UInt8] = [0x5C, 0x5D, 0x5E, 0x5F]

    // The box's unsolicited reports ('sl4q'), as it sends them.
    static let reportHidi: UInt8 = 0x40           // [5] length, [6...] messages: a thru or note 0x60 change
    static let reportOtherGone: UInt8 = 0x46      // [5] the other port's index: its computer disconnected
    static let reportOtherCame: UInt8 = 0x49      // [5] the other port's index: a computer connected there
    static let reportRateChange: UInt8 = 0x4B     // [5..7] the box's new rate, 24-bit big-endian

    static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        s.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }
    static let propStatus = fourCC("sl4s")
    static let propHID = fourCC("sl4h")
    static let propQueue = fourCC("sl4q")
    static let propMeters = fourCC("sl4m")
    static let propInSafety = fourCC("sl4i")

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// The SL 4's CoreAudio device, listed by the driver while a box is attached.
    static func device() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = deviceUID as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    /// The SL4Device plug-in is loaded in coreaudiod.
    static func pluginLoaded() -> Bool {
        var addr = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var bundle = pluginBundleID as CFString
        var plugin = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &bundle) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
        }
        return err == noErr && plugin != kAudioObjectUnknown
    }

    /// An SL 4 is in the USB registry (with or without the driver), under either product ID.
    static func boxOnUSB() -> Bool {
        productIDs.contains { pid in
            guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
            match["idVendor"] = vendorID
            match["idProduct"] = pid
            let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
            guard service != 0 else { return false }
            IOObjectRelease(service)
            return true
        }
    }

    /// The installed driver's version, from its bundle.
    static func driverVersion() -> String? {
        Bundle(path: driverBundlePath)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// A CFData property's bytes, or nil if the driver doesn't have it.
    static func data(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Data? {
        var addr = address(selector)
        var data: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &data) == noErr,
              let cf = data?.takeRetainedValue() else { return nil }
        return cf as Data
    }

    /// The driver's status packet; a shorter packet (an older driver) is zero-filled.
    static func status(_ dev: AudioObjectID) -> SL4StatusPacket? {
        guard let bytes = data(dev, propStatus) else { return nil }
        var packet = SL4StatusPacket()
        _ = withUnsafeMutableBytes(of: &packet) { dst in
            bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), count: min(bytes.count, dst.count))
        }
        return packet
    }

    /// The box's unsolicited reports queued for this app since its last read, oldest first.
    static func reports(_ dev: AudioObjectID) -> [[UInt8]] {
        guard let bytes = data(dev, propQueue) else { return [] }
        return stride(from: 0, to: bytes.count - reportLength + 1, by: reportLength).map {
            [UInt8](bytes[bytes.startIndex + $0 ..< bytes.startIndex + $0 + reportLength])
        }
    }

    /// The tag of the last HID command sent; each command gets the next one (never 0).
    @MainActor private static var lastTag: UInt32 = 0

    /// Send one HID command to the box and return its reply, or nil if it didn't take the command.
    @MainActor @discardableResult
    static func command(_ dev: AudioObjectID, _ cmd: UInt8, _ args: [UInt8] = []) -> [UInt8]? {
        // Build the report: [0] the command, [1..4] a new tag, [5...] the arguments.
        lastTag = lastTag == UInt32.max ? 1 : lastTag + 1
        var request = [UInt8](repeating: 0, count: reportLength)
        request[0] = cmd
        withUnsafeBytes(of: lastTag) { request.replaceSubrange(1...4, with: $0) }
        request.replaceSubrange(5..<(5 + args.count), with: args)
        // Writing 'sl4h' sends it.
        var addr = address(propHID)
        let cfIn = Data(request) as CFData
        var ref = Unmanaged.passUnretained(cfIn)   // the property's value is the CFDataRef itself
        let sent = withExtendedLifetime(cfIn) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFData>>.size), &ref)
        }
        guard sent == noErr else { return nil }
        // Reading 'sl4h' returns the box's reply: the same command and tag if it took the command
        // (0xFE if it refused it, 0xFF if it doesn't know it).
        guard let out = data(dev, propHID), out.count >= 5 else { return nil }
        let bytes = [UInt8](out)
        return bytes[0] == cmd && Array(bytes[1...4]) == Array(request[1...4]) ? bytes : nil
    }

    /// Switch a deck's (0-3) thru: Note On = analog thru, Note Off = USB audio. True if the box took it.
    @MainActor @discardableResult
    static func setThru(_ dev: AudioObjectID, deck: Int, on: Bool) -> Bool {
        command(dev, cmdHidi, [3, on ? midiNoteOn : midiNoteOff, noteThru[deck], 0]) != nil
    }

    /// The peak level (0...1) of inputs 1-10 then outputs 1-10 since the last read. Reading keeps the
    /// driver measuring for another second; nil if the driver has no meters.
    static func meters(_ dev: AudioObjectID) -> [Float]? {
        guard let bytes = data(dev, propMeters), bytes.count == 2 * channels * MemoryLayout<Float32>.size else { return nil }
        var peaks = [Float32](repeating: 0, count: 2 * channels)
        _ = peaks.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return peaks
    }

    /// An output volume as a slider position (0...1) and in dB, or nil if there is none: element 0 is the
    /// master, 1-10 the channels.
    static func volume(_ dev: AudioObjectID, element: UInt32 = 0) -> (scalar: Float, db: Float)? {
        var scalarAddr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        var dbAddr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, element)
        var scalar: Float32 = 0, db: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &scalarAddr, 0, nil, &size, &scalar) == noErr,
              AudioObjectGetPropertyData(dev, &dbAddr, 0, nil, &size, &db) == noErr else { return nil }
        return (scalar, db)
    }

    static func setVolume(_ dev: AudioObjectID, _ scalar: Float, element: UInt32 = 0) {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        var value = Float32(scalar)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The output mute, or nil if there is none.
    static func muted(_ dev: AudioObjectID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    static func setMuted(_ dev: AudioObjectID, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// System Settings' Sound pane, where the SL 4 can be chosen as the input device.
    static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")

    /// Set the input safety offset (microseconds). The driver takes it only with nothing streaming,
    /// then has CoreAudio set the device up again with it, which takes about half a second.
    @discardableResult
    static func setInputSafety(_ dev: AudioObjectID, _ us: Int) -> Bool {
        var addr = address(propInSafety)
        let number = us as CFNumber
        var ref = Unmanaged.passUnretained(number)   // the property's value is the CFNumberRef itself
        return withExtendedLifetime(number) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref)
        } == noErr
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The latency the driver reports in one direction, in frames: device latency, safety offset
    /// and the stream's latency (what an app adds to its own buffer).
    static func latencyFrames(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var total = uint32(dev, kAudioDevicePropertyLatency, scope) + uint32(dev, kAudioDevicePropertySafetyOffset, scope)
        var addr = address(kAudioDevicePropertyStreams, scope)
        var stream = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &stream) == noErr, stream != kAudioObjectUnknown {
            total += uint32(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        return total
    }
}

// MARK: - What the panel shows

struct BoxState: Equatable {
    var streaming: Bool
    var sampleRate: Int      // the device's rate, which follows the box's
    var boxRate: Int         // the box's own rate (0x4A / 0x4B); 0 if not known
    var firmware: String
    var firmwareOutdated: Bool   // older than SL4Driver.latestFirmware
    var serial: String
    var thru: [Bool]         // decks 1-4: true = analog thru
    var port: Int            // this Mac's USB port on the box: 1 = A, 2 = B, 0 = not known
    var otherPort: Int       // the other port: 1 = A, 2 = B, 0 = no computer there
    var fullSpeed: Bool      // connected at USB full speed, which carries no audio
    var outputLatencyMs: Double
    var inputLatencyMs: Double
    var volume: Volume?      // the master output volume; nil if none
    var channelVolumes: [Volume?]   // outputs 1-10; nil where there is none
    struct Volume: Equatable {
        let scalar: Float    // as a slider position, 0...1
        let db: Float
    }
    var muted: Bool?         // the output mute; nil if none
    var input: InputHealth?  // nil from a driver too old to report it
    struct InputHealth: Equatable {
        let safetyUs: Int        // the input safety offset (the setting, as CoreAudio is using it)
        let earlyRead: UInt32    // 0 not judged yet, 1 working, 2 not working
        let hubs: Int            // USB hubs between the box and the Mac
        let dropouts: UInt64     // IO cycles in which input wasn't captured in time, since the box connected
                                 // or the input safety offset changed
    }
}

enum PanelState: Equatable {
    case driverMissing      // the plug-in isn't loaded: nothing can reach the box
    case noBox              // no SL 4 attached
    case bootloader         // attached, but in its firmware updater: no audio
    case connected(BoxState)
}

/// A repeating timer on the main run loop in its common modes, so it keeps firing while a control is
/// being dragged (event tracking), which a timer in the default mode does not.
@MainActor
func repeatingTimer(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in body() } }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

func portName(_ port: Int) -> String {
    port == 1 ? "A" : port == 2 ? "B" : "?"
}

func rateName(_ hz: Int) -> String {
    hz == 48000 ? "48 kHz" : hz == 96000 ? "96 kHz" : hz == 0 ? "—" : String(format: "%.1f kHz", Double(hz) / 1000)
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState = .noBox
    @Published var driverVersion: String?
    /// A short-lived message about something the user just tried or the box just reported (shown with the
    /// warnings).
    @Published var notice: String?
    private var noticeGeneration = 0
    /// The level meters, which read the device this model finds (not published: they redraw alone).
    let meters = MeterModel()
    private var timer: Timer?
    private(set) var device: AudioObjectID?
    /// The device whose volume and mute changes we are told of, and the listener that hears them.
    private var watched: AudioObjectID?
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }
    private static let watchedProperties = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
        SL4Driver.address($0, kAudioObjectPropertyScopeOutput)
    }

    init() {
        meters.device = { [weak self] in self?.device }
        refresh()
        // The status changes from outside the app (the box's rate control, other apps, the other port,
        // plugging in): read it twice a second. The master volume and mute are followed as they change
        // (watch).
        timer = repeatingTimer(every: 0.5) { [weak self] in self?.refresh() }
    }

    /// Show a notice for a few seconds.
    func show(_ text: String) {
        notice = text
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.noticeGeneration == generation { self.notice = nil }
        }
    }

    /// Be told when the device's master volume or mute changes (the menu bar, the volume keys, Audio
    /// MIDI Setup), so the slider follows at once rather than at the next status read.
    private func watch(_ dev: AudioObjectID?) {
        guard dev != watched else { return }
        if let old = watched {
            for var addr in Self.watchedProperties {
                AudioObjectRemovePropertyListenerBlock(old, &addr, DispatchQueue.main, volumeListener)
            }
        }
        if let new = dev {
            for var addr in Self.watchedProperties {
                AudioObjectAddPropertyListenerBlock(new, &addr, DispatchQueue.main, volumeListener)
            }
        }
        watched = dev
    }

    /// Read the box's reports queued for this app and tell the user of the ones that change what the
    /// panel shows from outside it: the rate set on the box, a computer on the other port. (Thru changes,
    /// reported as 0x40, are in the status already.)
    private func readReports(_ dev: AudioObjectID) {
        for report in SL4Driver.reports(dev) {
            switch report[0] {
            case SL4Driver.reportRateChange:
                let hz = Int(report[5]) << 16 | Int(report[6]) << 8 | Int(report[7])
                show("The SL 4's sample rate was changed on the box, to \(rateName(hz)).")
            case SL4Driver.reportOtherCame:
                show("A computer connected to the SL 4's other USB port (\(portName(Int(report[5]) + 1))).")
            case SL4Driver.reportOtherGone:
                show("The computer on the SL 4's other USB port (\(portName(Int(report[5]) + 1))) disconnected.")
            default:
                break
            }
        }
    }

    func refresh() {
        driverVersion = SL4Driver.driverVersion()
        // No driver device: either no box, or no driver to list one.
        guard let dev = SL4Driver.device(), let s = SL4Driver.status(dev) else {
            device = nil
            watch(nil)
            state = SL4Driver.pluginLoaded() ? .noBox : .driverMissing
            return
        }
        device = dev
        watch(dev)
        // The bundle's version can't tell a debug build (make install DEBUG=1 replaces only the
        // binary in it); the running driver says so in its status.
        if s.debug_build != 0, let version = driverVersion { driverVersion = version + " (debug build)" }
        if s.boot_mode != 0 { state = .bootloader; return }
        if s.connected == 0 { state = .noBox; return }
        readReports(dev)
        // Connected: collect what the panel shows.
        let rate = Double(s.sample_rate > 0 ? s.sample_rate : 48000)
        let volume = SL4Driver.volume(dev)
        let serial = withUnsafeBytes(of: s.serial) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let thru = withUnsafeBytes(of: s.thru) { Array($0.prefix(SL4Driver.decks)) }
        state = .connected(BoxState(
            streaming: s.streaming != 0,
            sampleRate: Int(s.sample_rate),
            boxRate: Int(s.box_rate),
            firmware: s.version_maj == 0 && s.version_min == 0 ? "—" : String(format: "%u.%02u", s.version_maj, s.version_min),
            firmwareOutdated: (s.version_maj != 0 || s.version_min != 0) &&
                (Int(s.version_maj), Int(s.version_min)) < SL4Driver.latestFirmware,
            serial: serial.isEmpty ? "—" : serial,
            thru: thru.map { $0 != 0 },
            port: Int(s.port_a),
            otherPort: Int(s.port_b),
            fullSpeed: s.usb_link == 1,
            outputLatencyMs: Double(SL4Driver.latencyFrames(dev, kAudioObjectPropertyScopeOutput)) * 1000 / rate,
            inputLatencyMs: Double(SL4Driver.latencyFrames(dev, kAudioObjectPropertyScopeInput)) * 1000 / rate,
            volume: volume.map { BoxState.Volume(scalar: $0.scalar, db: $0.db) },
            channelVolumes: (1...UInt32(SL4Driver.channels)).map { element in
                SL4Driver.volume(dev, element: element).map { BoxState.Volume(scalar: $0.scalar, db: $0.db) }
            },
            muted: SL4Driver.muted(dev),
            input: s.in_safety_us == 0 ? nil : BoxState.InputHealth(
                safetyUs: Int(s.in_safety_us), earlyRead: s.early_read,
                hubs: Int(s.hub_depth), dropouts: s.in_dropouts)))
    }

    /// Set the master output volume (a slider position, 0...1); the menu bar and Audio MIDI Setup follow.
    /// Any level above the minimum unmutes, as the macOS volume slider does. The window updates from
    /// the volume and mute listener (watch), so a slider drag costs one set per step, not a refresh.
    func setVolume(_ scalar: Float, unmuting muted: Bool) {
        guard let dev = device else { return }
        SL4Driver.setVolume(dev, scalar)
        if scalar > 0, muted { SL4Driver.setMuted(dev, false) }
    }

    /// Set one output channel's volume (channel 1-10), then show it.
    func setChannelVolume(_ channel: Int, _ scalar: Float) {
        guard let dev = device else { return }
        SL4Driver.setVolume(dev, scalar, element: UInt32(channel))
        refresh()
    }

    func setMuted(_ muted: Bool) {
        guard let dev = device else { return }
        SL4Driver.setMuted(dev, muted)
    }

    /// Switch a deck's (0-3) analog thru, then show what the box reports.
    func setThru(deck: Int, on: Bool) {
        guard let dev = device else { return }
        if !SL4Driver.setThru(dev, deck: deck, on: on) {
            show("Deck \(deck + 1) wasn't switched: the SL 4 didn't take the command.")
        }
        // The box confirms the change with a report within a few milliseconds; the driver keeps it in
        // its status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refresh() }
    }

    /// Change the input safety offset. CoreAudio sets the device up again with it (the window shows the
    /// SL 4 as gone for a moment).
    func setInputSafety(_ us: Int) {
        guard let dev = device else { return }
        // Refused if an app started using the SL 4 since the window last looked: say so, for a while.
        if !SL4Driver.setInputSafety(dev, us) {
            show("The input safety offset wasn't changed: an app is using the SL 4.")
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }
}

/// The level meters: each channel's input and output, read from the driver 60 times a second. Kept
/// apart from PanelModel so the meters redraw on their own, not the whole window. They respond fast
/// (a new peak at once, falling the full range in a third of a second), so they show how promptly
/// audio, a DVS record's timecode for one, starts and stops.
@MainActor
final class MeterModel: ObservableObject {
    /// Peak level in dB (meterFloorDb...0) of each channel: inputs 1-10, then outputs 1-10.
    @Published var levels: [Float] = Array(repeating: MeterModel.meterFloorDb, count: 2 * SL4Driver.channels)
    static let meterFloorDb: Float = -60
    private static let ticksPerSecond = 60.0
    private static let fallDbPerTick: Float = 3     // 180 dB a second
    private var timer: Timer?
    /// The device to read, from PanelModel.
    var device: () -> AudioObjectID? = { nil }

    init() {
        timer = repeatingTimer(every: 1.0 / Self.ticksPerSecond) { [weak self] in self?.tick() }
    }

    private func tick() {
        // Read the driver only while the window can be seen: once nothing reads them, the driver stops
        // measuring (after a second), so a hidden or minimised panel costs nothing.
        guard NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) else { return }
        let peaks = device().flatMap { SL4Driver.meters($0) } ?? Array(repeating: 0, count: 2 * SL4Driver.channels)
        // A meter jumps up to a new peak and falls back fast, but not so fast that a short peak is gone
        // before it is drawn.
        let next = zip(levels, peaks).map { shown, peak in
            let db = peak > 0 ? max(20 * log10(peak), Self.meterFloorDb) : Self.meterFloorDb
            return max(db, shown - Self.fallDbPerTick)
        }
        // Publish only a change, so still meters don't redraw.
        if next != levels { levels = next }
    }
}

/// A horizontal level meter, from meterFloorDb to 0 dB: green, then yellow from -12 dB, red from -3 dB.
struct LevelMeter: View {
    let db: Float
    var label = "Level"
    var body: some View {
        GeometryReader { geo in
            let floor = MeterModel.meterFloorDb
            let fraction = CGFloat((db - floor) / -floor)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0),
                                                 .init(color: .green, location: 0.78),
                                                 .init(color: .yellow, location: 0.8),
                                                 .init(color: .yellow, location: 0.93),
                                                 .init(color: .red, location: 0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * max(0, min(1, fraction))) }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(db <= MeterModel.meterFloorDb ? "silent" : String(format: "%.0f dB", db))
    }
}

/// A stereo pair's meter: one bar for its left channel, one for its right.
struct StereoMeter: View {
    let left: Float, right: Float
    var body: some View {
        VStack(spacing: 3) {
            ForEach([("L", left), ("R", right)], id: \.0) { side, db in
                HStack(spacing: 6) {
                    Text(side).font(.caption2).foregroundStyle(.secondary).frame(width: 8)
                    LevelMeter(db: db, label: side == "L" ? "Left" : "Right")
                }
            }
        }
    }
}

/// The five stereo pairs' meters (decks 1-4 and Aux), one row each, observing the meters themselves so
/// that only they redraw as the levels move.
struct PairMeters: View {
    @ObservedObject var meters: MeterModel
    let first: Int   // index into meters.levels of the first pair's left channel: 0 inputs, 10 outputs
    var body: some View {
        ForEach(0..<PanelView.pairNames.count, id: \.self) { pair in
            LabeledContent(PanelView.pairNames[pair]) {
                StereoMeter(left: meters.levels[first + 2 * pair], right: meters.levels[first + 2 * pair + 1])
            }
            .help(PanelView.channelOrderNote)
        }
    }
}

// MARK: - The window

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.state {
            case .driverMissing:
                Message(symbol: "exclamationmark.triangle", title: "SL 4 driver not loaded",
                        text: "Install the Rane SL 4 driver package, then open this app again.")
            case .noBox:
                Message(symbol: "cable.connector", title: "No SL 4 connected",
                        text: "Connect the SL 4 by USB, directly or through a single hub.")
            case .bootloader:
                Message(symbol: "exclamationmark.triangle", title: "The SL 4 is in its firmware updater",
                        text: "The box started in its firmware updater and passes no audio until its firmware is written again.")
            case .connected(let box):
                connected(box)
            }
        }
        // Every piece of text can be selected and copied (a serial number, a warning to paste into a
        // report); controls' own labels stay controls.
        .textSelection(.enabled)
    }

    /// One column of the connected view: a grouped form sized to its sections, so it never scrolls.
    private func column<Content: View>(@ViewBuilder _ sections: () -> Content) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .frame(width: Self.columnWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
    static let columnWidth: CGFloat = 440
    /// The ten channels as stereo pairs, for inputs and outputs alike. Which pair is which deck has not
    /// been checked on a box: this is the assumed order (pairs 1-4 = decks 1-4, 9/10 = Aux).
    static let pairNames = ["Deck 1 (1/2)", "Deck 2 (3/4)", "Deck 3 (5/6)", "Deck 4 (7/8)", "Aux (9/10)"]
    static let channelOrderNote = "Channel order unverified: channels 1-8 are assumed to be decks 1-4 in pairs, and 9/10 Aux."

    @ViewBuilder
    private func connected(_ box: BoxState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            column { boxSections(box) }
            column { levelSections(box) }
        }
    }

    /// The left column: the box, its USB ports, its audio settings and the decks.
    @ViewBuilder
    private func boxSections(_ box: BoxState) -> some View {
        Section("Rane SL 4") {
            LabeledContent("Status", value: box.streaming ? "Connected, streaming audio" : "Connected")
            // The firmware in red if it's older than the newest Rane released, which is shown beside it.
            LabeledContent("Firmware") {
                if box.firmwareOutdated {
                    (Text(box.firmware).foregroundColor(.red) +
                     Text(String(format: " (latest: %d.%02d)", SL4Driver.latestFirmware.major, SL4Driver.latestFirmware.minor)))
                } else {
                    Text(box.firmware)
                }
            }
            LabeledContent("Serial number", value: box.serial)
            LabeledContent("Driver", value: model.driverVersion ?? "—")
            if let input = box.input {
                LabeledContent("USB", value: input.hubs == 0 ? "Connected directly" :
                                             input.hubs == 1 ? "Through 1 hub" : "Through \(input.hubs) hubs")
            }
        }
        Section {
            LabeledContent("This Mac", value: box.port == 0 ? "—" : "Port \(portName(box.port))")
            LabeledContent("Other port", value: box.otherPort == 0 ? "No computer" :
                                                "A computer is connected (port \(portName(box.otherPort)))")
        } header: {
            Text("USB ports")
        } footer: {
            Text("The SL 4 takes two computers, on its USB ports A and B.")
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Sample rate") {
                if box.boxRate != 0 && box.boxRate != box.sampleRate {
                    Text("\(rateName(box.sampleRate)), changing to \(rateName(box.boxRate))")
                } else {
                    Text(rateName(box.sampleRate))
                }
            }
            LabeledContent("Output latency", value: String(format: "%.1f ms", box.outputLatencyMs))
            LabeledContent("Input latency", value: String(format: "%.1f ms", box.inputLatencyMs))
            if let input = box.input {
                Picker("Input safety offset", selection: Binding(get: { input.safetyUs },
                                                                 set: { model.setInputSafety($0) })) {
                    ForEach(Self.safetyChoices(input.safetyUs), id: \.self) { us in
                        Text(Self.ms(us) + Self.safetyNote(us)).tag(us)
                    }
                }
                .disabled(box.streaming)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("The sample rate, 48 or 96 kHz, is set on the SL 4; the computer follows it. Latency as the driver reports it, not counting each app's own buffer (in Serato DJ: USB Buffer Size). Raise the input safety offset if you hear gaps in the input.")
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(0..<SL4Driver.decks, id: \.self) { deck in
                Toggle("Deck \(deck + 1) analog thru", isOn: Binding(get: { box.thru[deck] },
                                                                     set: { model.setThru(deck: deck, on: $0) }))
            }
        } header: {
            Text("Decks")
        } footer: {
            Text("Thru sends a deck's input straight to its outputs. An app playing through the SL 4 switches the decks to USB when it starts, and back to thru when it stops. Aux has no thru. The LINE / PHONO switches on the box are not reported to the computer.")
                .foregroundStyle(.secondary)
        }
    }

    /// The input safety offsets to choose from, with the current setting among them.
    static func safetyChoices(_ setting: Int) -> [Int] {
        let choices = [500, 1000, 1500, 2000, 3000, 4000, 8000]
        return choices.contains(setting) ? choices : (choices + [setting]).sorted()
    }
    /// Below the default, input can drop out under load.
    static func safetyNote(_ us: Int) -> String {
        us == 1500 ? " (default)" : us < 1500 ? " (not recommended)" : ""
    }
    static func ms(_ us: Int) -> String {
        us % 1000 == 0 ? "\(us / 1000) ms" : String(format: "%.1f ms", Double(us) / 1000)
    }

    /// What the panel warns about: a full-speed USB connection, input the driver couldn't
    /// read early, and input dropouts.
    static func warnings(_ box: BoxState) -> [String] {
        var w: [String] = []
        // At full speed the box enumerates without its audio interfaces.
        if box.fullSpeed {
            w.append("The SL 4 is connected at USB full speed, which carries no audio. Connect it to a USB 2.0 (high-speed) port.")
        }
        guard let input = box.input else { return w }
        // Where the early read doesn't work, input can drop out below 8 ms (completion delivery).
        if input.earlyRead == 2 && input.safetyUs < 8000 {
            w.append("Input can't be read early on this Mac, so it can drop out at \(ms(input.safetyUs)). Set the input safety offset to 8 ms.")
        }
        if input.dropouts > 0 {
            let times = input.dropouts == 1 ? "once" : "\(input.dropouts) times"
            w.append("Input dropped out \(times) since the SL 4 was connected or the input safety offset changed. If you hear gaps in the input, raise the input safety offset.")
        }
        return w
    }

    /// Over the input meters while no app is using the SL 4: there is nothing to measure then (the decks are
    /// on thru and the box sends no audio), so say how to make them move, with "Sound Settings" a link to it.
    private var inputsIdleNote: AttributedString {
        var text = AttributedString("Choose the SL 4 as your input device in ")
        var pane = AttributedString("Sound Settings")
        if let url = SL4Driver.soundSettings { pane.link = url }
        text.append(pane)
        return text
    }

    /// The right column: any warnings, the input and output levels, and the output volumes.
    @ViewBuilder
    private func levelSections(_ box: BoxState) -> some View {
        let warnings = (model.notice.map { [$0] } ?? []) + Self.warnings(box)
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section {
            // The meters as one block (a VStack, or the overlay would collapse the rows into one),
            // greyed out with a note over them while nothing streams.
            VStack(spacing: 12) {
                PairMeters(meters: model.meters, first: 0)
            }
            .padding(.vertical, 4)
            .opacity(box.streaming ? 1 : 0.3)
            .overlay {
                if !box.streaming {
                    Text(inputsIdleNote)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } header: {
            Text("Inputs")
        } footer: {
            Text("The level of each input channel while an app is using the SL 4 (as its input or output device). With nothing using it the decks are on thru, and the box sends the computer no audio. The channel order (decks 1-4, then Aux) has not been checked on a box.")
                .foregroundStyle(.secondary)
        }
        Section {
            if let volume = box.volume {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: Binding(get: { volume.scalar },
                                              set: { model.setVolume($0, unmuting: box.muted == true) }), in: 0...1)
                        Text(box.muted == true ? "Muted" : Self.dbText(volume))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            if let muted = box.muted {
                Toggle("Mute", isOn: Binding(get: { muted }, set: { model.setMuted($0) }))
            }
            PairMeters(meters: model.meters, first: SL4Driver.channels)
            if box.channelVolumes.contains(where: { $0 != nil }) {
                DisclosureGroup("Channel volumes") {
                    ForEach(0..<SL4Driver.channels, id: \.self) { ch in
                        if let volume = box.channelVolumes[ch] {
                            LabeledContent(Self.channelName(ch)) {
                                HStack {
                                    Slider(value: Binding(get: { volume.scalar },
                                                          set: { model.setChannelVolume(ch + 1, $0) }), in: 0...1)
                                    Text(Self.dbText(volume))
                                        .monospacedDigit()
                                        .frame(width: 52, alignment: .trailing)
                                }
                            }
                            .help(Self.channelOrderNote)
                        }
                    }
                }
            }
        } header: {
            Text("Outputs")
        } footer: {
            Text("The volume applies to everything the SL 4 plays, Serato's decks included, like the volume keys. Each channel's own volume is set under Channel volumes (or in Audio MIDI Setup).")
                .foregroundStyle(.secondary)
        }
    }

    /// An output channel (0-9) by its pair and side, e.g. "Deck 1 L (1)".
    static func channelName(_ ch: Int) -> String {
        let pair = ch / 2 < 4 ? "Deck \(ch / 2 + 1)" : "Aux"
        return "\(pair) \(ch % 2 == 0 ? "L" : "R") (\(ch + 1))"
    }
    static func dbText(_ volume: BoxState.Volume) -> String {
        volume.scalar <= 0 ? "Off" : String(format: "%.0f dB", volume.db)
    }
}

struct Message: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: PanelView.columnWidth)
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SL4ControlPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PanelModel()

    var body: some Scene {
        Window("SL 4 Control Panel", id: "main") {
            PanelView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
