#!/usr/bin/env swift
// LogiKeyPad direct-HID probe — MX Creative Keypad (046D:C354), no Options+.
//
// Protocol reference (open source): github.com/julusian/node-logitech-mx-creative-console
//   Report 0x11 (20 B): HID++ short — page buttons via reprogrammable-controls (feature idx 0x0B)
//   Report 0x13 (32 B): HID++ long  — LCD key presses [FF 02 00 00 01 <keyIds 1...9> 00...]
//   Report 0x14 (4095 B OUT): LCD JPEG tiles on a 480x480 panel; keys are 118x118 @ x=23+c*158, y=6+r*158
//
// Modes:
//   swift scripts/hid-probe.swift info
//   swift scripts/hid-probe.swift listen [seconds]   (sends page-button divert init writes first)
//   swift scripts/hid-probe.swift paint [keyIndex]   (one blue JPEG tile with its number; LCD proof)

import Foundation
import IOKit.hid
import AppKit

let VENDOR = 0x046D
let PRODUCT = 0xC354

func findDevice() -> IOHIDDevice? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [kIOHIDVendorIDKey as String: VENDOR,
                                   kIOHIDProductIDKey as String: PRODUCT]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
          let device = devices.first else { return nil }
    return device
}

func prop(_ device: IOHIDDevice, _ key: String) -> String {
    guard let v = IOHIDDeviceGetProperty(device, key as CFString) else { return "?" }
    return "\(v)"
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - info

func runInfo(device: IOHIDDevice) {
    print("Product:        \(prop(device, kIOHIDProductKey))")
    print("Manufacturer:   \(prop(device, kIOHIDManufacturerKey))")
    print("Serial:         \(prop(device, kIOHIDSerialNumberKey))")
    print("Transport:      \(prop(device, kIOHIDTransportKey))")
    print("VID:PID:        \(prop(device, kIOHIDVendorIDKey)):\(prop(device, kIOHIDProductIDKey))")
    print("MaxInputReport: \(prop(device, kIOHIDMaxInputReportSizeKey as String))")
    print("MaxOutputReport:\(prop(device, kIOHIDMaxOutputReportSizeKey as String))")
    print("MaxFeatureReport:\(prop(device, kIOHIDMaxFeatureReportSizeKey as String))")
    if let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] {
        var seen = Set<String>()
        print("Reports (from elements):")
        for el in elements {
            let rid = IOHIDElementGetReportID(el)
            let size = IOHIDElementGetReportSize(el) * IOHIDElementGetReportCount(el) / 8
            let type = IOHIDElementGetType(el).rawValue
            let key = "id=0x\(String(rid, radix: 16)) type=\(type) bytes=\(size)"
            if seen.insert(key).inserted { print("  \(key)") }
        }
    }
    let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("Open result:    0x\(String(UInt32(bitPattern: ret), radix: 16)) \(ret == kIOReturnSuccess ? "(success — direct access works)" : "(FAILED)")")
    if ret == kIOReturnSuccess { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
}

// MARK: - shared send

/// Sends a full packet whose byte[0] IS the report ID.
/// Empirically on macOS, IOHIDDeviceSetReport sends the buffer verbatim;
/// omitting the ID byte shifts the frame and the device ignores it.
func sendReport(_ device: IOHIDDevice, packetWithId: [UInt8]) -> Bool {
    guard let id = packetWithId.first else { return false }
    let ret = packetWithId.withUnsafeBufferPointer { buf in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), buf.baseAddress!, CFIndex(buf.count))
    }
    if ret != kIOReturnSuccess {
        print("  !! SetReport id=0x\(String(id, radix: 16)) failed: 0x\(String(UInt32(bitPattern: ret), radix: 16))")
    }
    return ret == kIOReturnSuccess
}

/// HID++ request on 0x11: [11, FF, featureIdx, (fn<<4)|0x0B, params..., 0-pad to 20]
func hidppRequest(feature: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
    var p: [UInt8] = [0x11, 0xFF, feature, (function << 4) | 0x0B] + params
    p += [UInt8](repeating: 0, count: max(0, 20 - p.count))
    return Array(p.prefix(20))
}

// MARK: - listen

final class Probe: @unchecked Sendable {
    var downLCD = Set<Int>()
    var downPage = Set<Int>()
    let t0 = Date()
    func stamp() -> String { String(format: "%7.0fms", Date().timeIntervalSince(t0) * 1000) }

    func handle(reportID: Int, bytes: [UInt8]) {
        print("\(stamp()) IN  id=0x\(String(reportID, radix: 16)) len=\(bytes.count)  \(hex(bytes))")
        fflush(stdout)
        if reportID == 0x13, bytes.count >= 5, bytes[0] == 0xFF, bytes[1] == 0x02, bytes[4] == 0x01 {
            let now = Set(bytes[5...].prefix(while: { $0 != 0 }).map(Int.init))
            for k in now.subtracting(downLCD).sorted() { print("\(stamp())   >>> LCD KEY \(k) DOWN (slot \(k), row \((k - 1) / 3) col \((k - 1) % 3))") }
            for k in downLCD.subtracting(now).sorted() { print("\(stamp())   <<< LCD KEY \(k) UP") }
            downLCD = now
            fflush(stdout)
        }
        if reportID == 0x11, bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0x0B, bytes[2] == 0x00 {
            var now = Set<Int>()
            var i = 3
            while i + 1 < bytes.count {
                let v = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                if v == 0 { break }
                now.insert(v); i += 2
            }
            for k in now.subtracting(downPage).sorted() { print("\(stamp())   >>> PAGE \(k == 0x01A1 ? "LEFT" : k == 0x01A2 ? "RIGHT" : String(format: "0x%04x", k)) DOWN") }
            for k in downPage.subtracting(now).sorted() { print("\(stamp())   <<< PAGE 0x\(String(k, radix: 16)) UP") }
            downPage = now
            fflush(stdout)
        }
    }
}

var keepAliveBuffers: [UnsafeMutableBufferPointer<UInt8>] = []
let probe = Probe()

func registerReports(_ device: IOHIDDevice) {
    // ONE registration covers all report IDs; the buffer must fit the
    // largest input report (registering per-ID replaces the buffer and
    // silently truncates/drops reports — learned from capture #1).
    // macOS delivers the buffer WITH the report-ID byte at [0].
    let ctx = Unmanaged.passUnretained(probe).toOpaque()
    let size = 64
    let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: size)
    buf.initialize(repeating: 0)
    keepAliveBuffers.append(buf)
    IOHIDDeviceRegisterInputReportCallback(device, buf.baseAddress!, CFIndex(size), { context, _, _, _, reportID, report, reportLength in
        guard let context else { return }
        let p = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
        var bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
        if bytes.first == UInt8(reportID) { bytes.removeFirst() }  // strip ID byte
        p.handle(reportID: Int(reportID), bytes: bytes)
    }, ctx)
}

func runListen(device: IOHIDDevice, seconds: Int) {
    let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard ret == kIOReturnSuccess else {
        print("Open failed: 0x\(String(UInt32(bitPattern: ret), radix: 16)) — if NotPermitted, grant Input Monitoring to your terminal.")
        return
    }
    registerReports(device)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    // Library init writes: divert page buttons (0x01A1/0x01A2) to software via feature idx 0x0B fn 3.
    for control: UInt16 in [0x01A1, 0x01A2] {
        let ok = sendReport(device, packetWithId:
            hidppRequest(feature: 0x0B, function: 3, params: [UInt8(control >> 8), UInt8(control & 0xFF), 0x03]))
        print("init: divert page control 0x\(String(control, radix: 16)) -> \(ok ? "sent" : "FAILED")")
    }
    print("LISTENING \(seconds)s — press: LCD keys 1-9 in order, page ◀ ▶, hold one key 2s, press two keys together.")
    fflush(stdout)
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.25, true)
    }
    print("done. LCD keys seen down at least once tracked live above.")
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// MARK: - hidpp diagnostics (is the OUT path alive? discover feature index)

func spinRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
}

func runHidpp(device: IOHIDDevice) {
    let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard ret == kIOReturnSuccess else { print("Open failed"); return }
    registerReports(device)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    spinRunLoop(0.5)  // let the queue go live BEFORE sending (answers must not be missed)

    // HID++ Root feature (index 0): fn1 = ping (echoes 3 param bytes), fn0 = getFeature(id hi, id lo)
    print(">> ping (root fn1, params AA BB CC)")
    _ = sendReport(device, packetWithId: hidppRequest(feature: 0x00, function: 1, params: [0xAA, 0xBB, 0xCC]))
    spinRunLoop(1.0)

    print(">> getFeature 0x1B04 (reprogrammable controls v4) via root fn0")
    _ = sendReport(device, packetWithId: hidppRequest(feature: 0x00, function: 0, params: [0x1B, 0x04]))
    spinRunLoop(1.0)

    print(">> getFeature 0x1B00 / 0x0003 (device info) via root fn0")
    _ = sendReport(device, packetWithId: hidppRequest(feature: 0x00, function: 0, params: [0x00, 0x03]))
    spinRunLoop(1.0)

    print(">> divert page-left using library index 0x0B (for comparison)")
    _ = sendReport(device, packetWithId: hidppRequest(feature: 0x0B, function: 3, params: [0x01, 0xA1, 0x03]))
    spinRunLoop(1.0)
    print("hidpp diagnostics done — answers (if any) are the IN lines above.")
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

/// Variant matrix for the silent OUT path: same ping, different framings.
func runPingVariants(device: IOHIDDevice) {
    let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard ret == kIOReturnSuccess else { print("Open failed"); return }
    registerReports(device)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    spinRunLoop(0.5)

    // B: buffer WITH report-ID byte included (20 bytes after param id)
    print(">> B: ping, ID byte included in buffer")
    _ = sendReport(device, packetWithId: hidppRequest(feature: 0, function: 1, params: [0xB0, 0xB1, 0xB2]))
    spinRunLoop(0.8)

    // C: device index 0x00 instead of 0xFF
    print(">> C: ping, device index 0x00")
    var c = hidppRequest(feature: 0, function: 1, params: [0xC0, 0xC1, 0xC2]); c[1] = 0x00 // device-index byte
    _ = sendReport(device, packetWithId: c)
    spinRunLoop(0.8)

    // D: same request as 32-byte report 0x13
    print(">> D: ping via report 0x13 (31-byte payload)")
    var d = hidppRequest(feature: 0, function: 1, params: [0xD0, 0xD1, 0xD2])
    d += [UInt8](repeating: 0, count: 31 - d.count)
    _ = sendReport(device, packetWithId: { var dd = d; dd[0] = 0x13; return dd }())
    spinRunLoop(0.8)

    // E: classic HID++ 1.0 ping on short report 0x10 (6-byte payload) — not in descriptor, expect failure
    print(">> E: HID++1.0 ping via report 0x10 (not in descriptor; control case)")
    _ = sendReport(device, packetWithId: [0x10, 0xFF, 0x00, 0x1B, 0xE0, 0xE1, 0xE2])
    spinRunLoop(0.8)
    print("variants done.")
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// MARK: - paint (LCD proof)

func runPaint(device: IOHIDDevice, keyIndex: Int) {
    let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard ret == kIOReturnSuccess else { print("Open failed"); return }
    registerReports(device)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    // Render EXACTLY 118x118 pixels (not points — an NSImage lockFocus on a
    // Retina machine produces 236x236 and the tile spans 4 keys; IMG_0635).
    let size = 118
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        print("bitmap create failed"); return
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor(red: 0.02, green: 0.18, blue: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let text = "\(keyIndex + 1)"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 64, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let ts = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (CGFloat(size) - ts.width) / 2, y: (CGFloat(size) - ts.height) / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
        print("JPEG encode failed"); return
    }
    print("JPEG: \(jpeg.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh)px for key \(keyIndex + 1)")

    // Chunk into 4095-B report-0x14 packets per imageWriter.ts (byte0 handled by IOKit).
    let col = keyIndex % 3, row = keyIndex / 3
    let x: UInt16 = UInt16(23 + col * 158), y: UInt16 = UInt16(6 + row * 158)
    let bytes = [UInt8](jpeg)
    let maxPacket = 4095
    func packetByte(_ index: Int, first: Bool, last: Bool) -> UInt8 {
        var v = UInt8(index) | 0b00100000
        if first { v |= 0b10000000 }
        if last { v |= 0b01000000 }
        return v
    }
    func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    var packets: [[UInt8]] = []
    let headerLen = 20
    let firstCount = min(bytes.count, maxPacket - headerLen)
    var p1 = [UInt8](repeating: 0, count: maxPacket)
    // library layout incl. report-id byte at [0]; we build same then strip [0] for IOKit
    p1[0] = 0x14; p1[1] = 0xFF; p1[2] = 0x02; p1[3] = 0x2B
    p1[4] = packetByte(1, first: true, last: firstCount >= bytes.count)
    p1.replaceSubrange(5..<7, with: be16(0x0100))
    p1.replaceSubrange(7..<9, with: be16(0x0100))
    p1.replaceSubrange(9..<11, with: be16(x))
    p1.replaceSubrange(11..<13, with: be16(y))
    p1.replaceSubrange(13..<15, with: be16(UInt16(size)))
    p1.replaceSubrange(15..<17, with: be16(UInt16(size)))
    p1.replaceSubrange(18..<20, with: be16(UInt16(bytes.count)))
    p1.replaceSubrange(headerLen..<(headerLen + firstCount), with: bytes.prefix(firstCount))
    packets.append(p1)
    var remaining = bytes.count - firstCount
    var part = 2
    while remaining > 0 {
        let count = min(remaining, maxPacket - 5)
        let offset = bytes.count - remaining
        remaining -= count
        var p = [UInt8](repeating: 0, count: maxPacket)
        p[0] = 0x14; p[1] = 0xFF; p[2] = 0x02; p[3] = 0x2B
        p[4] = packetByte(part, first: false, last: remaining == 0)
        p.replaceSubrange(5..<(5 + count), with: bytes[offset..<(offset + count)])
        packets.append(p)
        part += 1
    }
    for (i, p) in packets.enumerated() {
        print("send packet \(i + 1)/\(packets.count) (\(p.count) B payload): \(sendReport(device, packetWithId: p))")
        CFRunLoopRunInMode(.defaultMode, 0.05, true)  // let acks arrive
    }
    print("waiting 2s for acks (watch key \(keyIndex + 1) on the device)…")
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.25, true) }
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// MARK: - main

let args = CommandLine.arguments
guard let device = findDevice() else {
    print("MX Creative Keypad (046D:C354) not found. Is it plugged in via USB-C?")
    exit(1)
}
switch args.dropFirst().first ?? "info" {
case "info": runInfo(device: device)
case "listen": runListen(device: device, seconds: Int(args.dropFirst(2).first ?? "90") ?? 90)
case "hidpp": runHidpp(device: device)
case "pingx": runPingVariants(device: device)
case "paint": runPaint(device: device, keyIndex: min(8, max(0, Int(args.dropFirst(2).first ?? "0") ?? 0)))
default: print("usage: hid-probe.swift [info|listen [s]|paint [0-8]]")
}
