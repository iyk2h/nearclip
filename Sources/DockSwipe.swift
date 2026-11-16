import CoreGraphics
import Foundation
import Darwin

// A small, versioned allowlist. No serialized native event or arbitrary field
// number is accepted from a peer. Finger count is resolved by the source OS.
struct DockSwipePacket: Codable {
    var token: UUID
    let axis: Int
    let phase: Int
    let progress: Double
    var velocityX: Double = 0
    var velocityY: Double = 0
    var inverted: Bool = false
    var isTerminal: Bool { phase == 4 || phase == 8 }
    var cancelled: Self {
        Self(token: token, axis: axis, phase: 8, progress: progress, inverted: inverted)
    }
    func validate() throws {
        guard (1...2).contains(axis), [1, 2, 4, 8].contains(phase),
              progress.isFinite, abs(progress) <= 16,
              velocityX.isFinite, velocityY.isFinite,
              abs(velocityX) <= 10000, abs(velocityY) <= 10000 else {
            throw ClipError.invalid("잘못된 트랙패드 제스처예요.")
        }
    }
}

enum DockSwipeAdapter {
    // Undocumented Dock event layout: isolate it here and do not advertise on
    // unknown OS generations. References and test limits: docs/GESTURES.md.
    // ProcessInfo can expose the SDK compatibility version (10.16) in older
    // launch environments. Read the product version from the kernel first.
    static func supportedMajor(productVersion: String?, reportedMajor: Int) -> Int {
        guard let value = productVersion, value.utf8.count <= 64,
              let first = value.split(separator: ".").first,
              !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }),
              let major = Int(first), (10...99).contains(major) else { return reportedMajor }
        return major
    }
    static let systemMajor: Int = {
        var length = 0
        guard sysctlbyname("kern.osproductversion", nil, &length, nil, 0) == 0,
              length > 0, length <= 128 else { return ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osproductversion", &bytes, &length, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        }
        return supportedMajor(productVersion: String(cString: bytes), reportedMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }()
    static func supports(major: Int) -> Bool { (13...27).contains(major) }
    static var available: Bool { supports(major: systemMajor) }
    static var naturalScrolling: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }
    static func renderingPacket(_ packet: DockSwipePacket, osMajor: Int, naturalScrolling: Bool) -> DockSwipePacket {
        // Captured horizontal progress is a logical Dock direction. macOS 27
        // posts that direction with the opposite sign, then applies the local
        // natural-scroll preference. Vertical gestures use their existing path.
        guard osMajor == 27, packet.axis == 1 else { return packet }
        let sign = naturalScrolling ? -1.0 : 1.0
        return DockSwipePacket(token: packet.token, axis: packet.axis, phase: packet.phase,
            progress: packet.progress * sign, velocityX: packet.velocityX * sign,
            velocityY: packet.velocityY, inverted: false)
    }
    static let eventMask: CGEventMask = (1 << 29) | (1 << 30)
    static func nativeType(_ event: CGEvent) -> Int64 { event.getIntegerValueField(CGEventField(rawValue: 55)!) }
    private static func field(_ value: UInt32) -> CGEventField { CGEventField(rawValue: value)! }
    static func read(_ event: CGEvent, token: UUID) -> DockSwipePacket? {
        guard available, nativeType(event) == 30,
              event.getIntegerValueField(field(110)) == 23 else { return nil }
        let packet = DockSwipePacket(token: token, axis: Int(event.getIntegerValueField(field(123))),
            phase: Int(event.getIntegerValueField(field(132))), progress: event.getDoubleValueField(field(124)),
            velocityX: event.getDoubleValueField(field(129)), velocityY: event.getDoubleValueField(field(130)),
            inverted: event.getIntegerValueField(field(136)) != 0)
        return (try? packet.validate()) != nil ? packet : nil
    }
    // On 27 the source Dock needs the physical terminal event to close its
    // gesture state, even when NearClip consumed the preceding swipe. Clear its
    // motion so completing local tracking does not switch a second desktop.
    static func localTermination(_ event: CGEvent, packet: DockSwipePacket, osMajor: Int = systemMajor) -> CGEvent? {
        guard osMajor == 27, packet.isTerminal else { return nil }
        for key: UInt32 in [124, 129, 130] { event.setDoubleValueField(field(key), value: 0) }
        event.setIntegerValueField(field(135), value: 0)
        return event
    }
    static func events(_ packet: DockSwipePacket, at point: CGPoint, marker: Int64, osMajor: Int = systemMajor,
                       naturalScrolling: Bool? = nil) -> [CGEvent] {
        guard supports(major: osMajor), (try? packet.validate()) != nil,
              let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return [] }
        let packet = renderingPacket(packet, osMajor: osMajor, naturalScrolling: naturalScrolling ?? Self.naturalScrolling)
        event.type = CGEventType(rawValue: 30)!
        companion.type = CGEventType(rawValue: 29)!
        for item in [event, companion] {
            item.location = point
            item.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        for (key, value) in [(110, 23), (123, packet.axis), (165, packet.axis), (132, packet.phase), (134, packet.phase)] {
            event.setDoubleValueField(field(UInt32(key)), value: Double(value))
        }
        event.setDoubleValueField(field(124), value: packet.progress)
        event.setDoubleValueField(field(129), value: packet.velocityX)
        event.setDoubleValueField(field(130), value: packet.velocityY)
        event.setIntegerValueField(field(135), value: Int64(Float(packet.progress).bitPattern))
        event.setIntegerValueField(field(136), value: packet.inverted ? 1 : 0)
        // Older Dock versions use the equivalent float-bit axis representation.
        let axisBits = Double(Float(bitPattern: UInt32(packet.axis)))
        event.setDoubleValueField(field(119), value: axisBits)
        event.setDoubleValueField(field(139), value: axisBits)
        if osMajor == 27 {
            guard let augmented = augment(event, packet: packet) else { return [] }
            // CGEvent deserialization does not preserve eventSourceUserData.
            // Restore it after conversion so the receiver cannot reclaim the
            // session in response to its own synthetic gesture.
            augmented.setIntegerValueField(.eventSourceUserData, value: marker)
            augmented.location = point
            return [augmented, companion]
        }
        return [event, companion]
    }

    // macOS 27 also reads a serialized IOHID payload. Construct it locally from
    // the validated, typed packet, never from bytes supplied by the peer.
    // Layout adapted from InstantSpaceSwitcher (MIT), see THIRD_PARTY_NOTICES.md.
    static func hidPayload(_ packet: DockSwipePacket, timestamp: UInt64) -> Data? {
        guard (try? packet.validate()) != nil else { return nil }
        let velocity = packet.velocityX != 0 || packet.velocityY != 0 || packet.phase == 4
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func fixed(_ value: Double) -> Int32 {
            let result = Int32(value * 65536)
            return result == 0 && value != 0 ? (value > 0 ? 1 : -1) : result
        }
        append(timestamp); append(UInt64(0)) // timestamp, sender
        append(UInt32(0)); append(UInt32(0)); append(UInt32(velocity ? 2 : 1))
        append(UInt32(40)); append(UInt32(23)); append(UInt32(packet.phase) << 24)
        append(UInt32(0)) // depth and reserved bytes
        append(Int32(0)); append(Int32(0)); append(Int32(0)) // positions
        append(UInt32(0)) // swipe mask
        append(UInt16(packet.axis)); append(UInt16(3)) // motion, Dock primary flavor
        append(fixed(packet.progress))
        if velocity {
            append(UInt32(28)); append(UInt32(9)); append(UInt32(0))
            append(UInt32(1)) // child depth 1, reserved bytes zero
            append(fixed(packet.velocityX)); append(fixed(packet.velocityY)); append(Int32(0))
        }
        return data
    }
    private static func augment(_ event: CGEvent, packet: DockSwipePacket) -> CGEvent? {
        guard let raw = event.data,
              let payload = hidPayload(packet, timestamp: event.timestamp) else { return nil }
        var data = raw as Data
        guard data.count >= 4, data.count <= 65536, data.prefix(4) == Data([0, 0, 0, 2]),
              payload.count == 68 || payload.count == 96 else { return nil }
        // Version-2 CGEvent extension: byte length and field 4205, big endian.
        data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255), 0x10, 0x6D])
        data.append(payload)
        return CGEvent(withDataAllocator: nil, data: data as CFData)
    }
}
