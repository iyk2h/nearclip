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
    static var available: Bool { (13...26).contains(systemMajor) }
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
    static func events(_ packet: DockSwipePacket, at point: CGPoint, marker: Int64) -> [CGEvent] {
        guard available, (try? packet.validate()) != nil,
              let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return [] }
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
        return [event, companion]
    }
}
