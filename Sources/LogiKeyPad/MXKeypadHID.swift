import Foundation
import AppKit
import IOKit.hid

// Direct-HID driver for the MX Creative Keypad (046D:C354) — no Options+.
// Protocol (open source, verified live by scripts/hid-probe.swift):
//   0x11 HID++ short (page buttons, feature idx 0x0B) · 0x13 key presses · 0x14 LCD JPEG tiles
//   Panel: one 480x480 canvas; keys 118x118 at x=23+c*158, y=6+r*158, ids 1...9 row-major.
//   macOS quirk: IOHIDDeviceSetReport buffers must INCLUDE the report-ID byte.

// MARK: - Pure packet builders (unit-tested)

enum HIDPP {
    /// [11, FF, feature, (fn<<4)|0x0B, params..., 0-pad to 20]
    static func request(feature: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x11, 0xFF, feature, (function << 4) | 0x0B] + params
        p += [UInt8](repeating: 0, count: max(0, 20 - p.count))
        return Array(p.prefix(20))
    }

    static func divertPageButton(control: UInt16) -> [UInt8] {
        request(feature: 0x0B, function: 3, params: [UInt8(control >> 8), UInt8(control & 0xFF), 0x03])
    }

    /// Parses a 0x13 button report payload (report-ID byte already stripped).
    /// Returns currently-down key ids (1...9), or nil if not a button report.
    static func parseButtonReport(_ b: [UInt8]) -> Set<Int>? {
        guard b.count >= 5, b[0] == 0xFF, b[1] == 0x02, b[2] == 0x00, b[4] == 0x01 else { return nil }
        return Set(b[5...].prefix(while: { $0 != 0 }).map(Int.init))
    }

    /// Parses a 0x11 page-button notification (feature 0x0B). Returns down control ids.
    static func parsePageReport(_ b: [UInt8]) -> Set<Int>? {
        guard b.count >= 3, b[0] == 0xFF, b[1] == 0x0B, b[2] == 0x00 else { return nil }
        var out = Set<Int>()
        var i = 3
        while i + 1 < b.count {
            let v = Int(b[i]) << 8 | Int(b[i + 1])
            if v == 0 { break }
            out.insert(v); i += 2
        }
        return out
    }

    static func isImageAck(_ b: [UInt8]) -> Bool {
        b.count >= 3 && b[0] == 0xFF && b[1] == 0x02 && b[2] == 0x2B
    }
}

enum ImagePacket {
    static let maxPacket = 4095

    /// Splits a JPEG into 0x14 packets for region (x,y,w,h). Byte[0]=0x14 included.
    static func make(jpeg: [UInt8], x: UInt16, y: UInt16, w: UInt16, h: UInt16) -> [[UInt8]] {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func packetByte(_ index: Int, first: Bool, last: Bool) -> UInt8 {
            var v = UInt8(index) | 0b00100000
            if first { v |= 0b10000000 }
            if last { v |= 0b01000000 }
            return v
        }
        var packets: [[UInt8]] = []
        let headerLen = 20
        let firstCount = min(jpeg.count, maxPacket - headerLen)
        var p1 = [UInt8](repeating: 0, count: maxPacket)
        p1[0] = 0x14; p1[1] = 0xFF; p1[2] = 0x02; p1[3] = 0x2B
        p1[4] = packetByte(1, first: true, last: firstCount >= jpeg.count)
        p1.replaceSubrange(5..<7, with: be16(0x0100))
        p1.replaceSubrange(7..<9, with: be16(0x0100))
        p1.replaceSubrange(9..<11, with: be16(x))
        p1.replaceSubrange(11..<13, with: be16(y))
        p1.replaceSubrange(13..<15, with: be16(w))
        p1.replaceSubrange(15..<17, with: be16(h))
        p1.replaceSubrange(18..<20, with: be16(UInt16(min(jpeg.count, 0xFFFF))))
        p1.replaceSubrange(headerLen..<(headerLen + firstCount), with: jpeg.prefix(firstCount))
        packets.append(p1)
        var remaining = jpeg.count - firstCount
        var part = 2
        while remaining > 0 {
            let count = min(remaining, maxPacket - 5)
            let offset = jpeg.count - remaining
            remaining -= count
            var p = [UInt8](repeating: 0, count: maxPacket)
            p[0] = 0x14; p[1] = 0xFF; p[2] = 0x02; p[3] = 0x2B
            p[4] = packetByte(part, first: false, last: remaining == 0)
            p.replaceSubrange(5..<(5 + count), with: jpeg[offset..<(offset + count)])
            packets.append(p)
            part += 1
        }
        return packets
    }
}

// MARK: - Driver

@MainActor
final class MXKeypadHID: ObservableObject {
    @Published private(set) var connected = false

    var onKey: ((Int, Bool) -> Void)?       // slot 0...8, isDown
    var onPageButton: ((Bool) -> Void)?     // true = right/next, false = left/prev
    var onConnectionChange: ((Bool) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutableBufferPointer<UInt8>?
    private var downKeys = Set<Int>()
    private var downPages = Set<Int>()
    private var ackCount = 0
    private var painting = false

    static let pageLeftID = 0x01A1
    static let pageRightID = 0x01A2

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDVendorIDKey as String: 0x046D,
                                       kIOHIDProductIDKey as String: 0xC354]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, dev in
            guard let context else { return }
            let driver = Unmanaged<MXKeypadHID>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { driver.connect(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, dev in
            guard let context else { return }
            let driver = Unmanaged<MXKeypadHID>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { driver.disconnect(dev) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        if let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let dev = devices.first {
            connect(dev)
        }
    }

    private func connect(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = dev
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
        buf.initialize(repeating: 0)
        reportBuffer = buf
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buf.baseAddress!, 64, { context, _, _, _, reportID, report, reportLength in
            guard let context else { return }
            let driver = Unmanaged<MXKeypadHID>.fromOpaque(context).takeUnretainedValue()
            var bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
            if bytes.first == UInt8(reportID) { bytes.removeFirst() }
            let rid = Int(reportID)
            MainActor.assumeIsolated { driver.handle(reportID: rid, bytes: bytes) }
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Divert page buttons to software (volatile; re-sent every connect).
        _ = send(HIDPP.divertPageButton(control: UInt16(Self.pageLeftID)))
        _ = send(HIDPP.divertPageButton(control: UInt16(Self.pageRightID)))
        connected = true
        onConnectionChange?(true)
    }

    private func disconnect(_ dev: IOHIDDevice) {
        guard let current = device, current == dev else { return }
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        downKeys.removeAll(); downPages.removeAll()
        connected = false
        onConnectionChange?(false)
    }

    private func handle(reportID: Int, bytes: [UInt8]) {
        if HIDPP.isImageAck(bytes) { ackCount += 1; return }
        if reportID == 0x13, let now = HIDPP.parseButtonReport(bytes) {
            for k in now.subtracting(downKeys).sorted() { onKey?(k - 1, true) }
            for k in downKeys.subtracting(now).sorted() { onKey?(k - 1, false) }
            downKeys = now
        } else if reportID == 0x11, let now = HIDPP.parsePageReport(bytes) {
            for k in now.subtracting(downPages) {
                if k == Self.pageRightID { onPageButton?(true) }
                if k == Self.pageLeftID { onPageButton?(false) }
            }
            downPages = now
        }
    }

    @discardableResult
    private func send(_ packet: [UInt8]) -> Bool {
        guard let device, let id = packet.first else { return false }
        let ret = packet.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), buf.baseAddress!, CFIndex(buf.count))
        }
        return ret == kIOReturnSuccess
    }

    /// Paints one JPEG region, awaiting per-packet ACKs (250 ms timeout each;
    /// the device silently drops packets sent while busy).
    func paint(jpeg: Data, x: UInt16, y: UInt16, w: UInt16, h: UInt16) async {
        guard connected, !painting else { return }
        painting = true
        defer { painting = false }
        for packet in ImagePacket.make(jpeg: [UInt8](jpeg), x: x, y: y, w: w, h: h) {
            let before = ackCount
            guard send(packet) else { return }
            let deadline = Date().addingTimeInterval(0.25)
            while ackCount == before, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}
