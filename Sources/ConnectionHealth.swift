import Foundation

enum InputSharingStatus: String {
    case off = "꺼짐", disconnected = "연결 대기", recovering = "연결 복구 중"
    case permission = "권한 필요", suspended = "일시 대기", peerOff = "상대 켜기 대기", ready = "사용 가능"
    static func resolve(requested: Bool, connected: Bool, inputReady: Bool, permissions: Bool,
                        captureEnabled: Bool, peerEnabled: Bool, paused: Bool) -> Self {
        guard requested else { return .off }
        guard connected else { return .disconnected }
        guard permissions else { return .permission }
        guard inputReady else { return .recovering }
        guard captureEnabled, !paused else { return .suspended }
        return peerEnabled ? .ready : .peerOff
    }
}

struct AppVersion: Codable, Equatable, Comparable {
    let version: String
    let build: Int
    var components: [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              build >= 0 && build <= 1_000_000 else { return nil }
        return parts.compactMap { Int($0) }
    }
    var label: String { "\(version) · build \(build)" }
    static var current: Self {
        Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.3",
             build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        guard let a = lhs.components, let b = rhs.components else { return false }
        return a == b ? lhs.build < rhs.build : a.lexicographicallyPrecedes(b)
    }
    static func releaseTag(_ tag: String) -> Self? {
        let raw = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = raw.components(separatedBy: "-build")
        guard pieces.count <= 2 else { return nil }
        let build = pieces.count == 2 ? Int(pieces[1]) : 0
        guard let build else { return nil }
        let value = Self(version: pieces[0], build: build)
        return value.components == nil ? nil : value
    }
    func peerNotice(_ peer: Self?) -> String {
        guard let peer else { return "이 Mac \(label) · 상대 버전 확인 불가\n상대도 최신 빌드로 업데이트하면 버전을 확인할 수 있어요." }
        if self == peer { return "양쪽 버전 같음 · \(label)" }
        return "버전이 달라요 · 이 Mac \(label) / 상대 \(peer.label)\n같은 빌드로 맞추면 새 기능을 함께 사용할 수 있어요."
    }
}

struct InputHealth: Equatable {
    let samples: Int
    let rttMS: Double
    let p95MS: Double
    let jitterMS: Double
    let queueMaxMS: Double
    var label: String {
        "왕복 \(Int(rttMS.rounded()))ms · p95 \(Int(p95MS.rounded()))ms · 편차 \(Int(jitterMS.rounded()))ms · 입력 대기 최대 \(Int(queueMaxMS.rounded()))ms"
    }
}

struct InputMeasurements {
    private(set) var pending: (UUID, TimeInterval)?
    private var samples: [Double] = []
    private var queueSamples: [Double] = []
    mutating func begin(now: TimeInterval) -> UUID? {
        guard pending == nil else { return nil }
        let id = UUID(); pending = (id, now); return id
    }
    mutating func receive(_ id: UUID, now: TimeInterval) -> Bool {
        guard let (expected, started) = pending, expected == id, now >= started else { return false }
        pending = nil; samples.append((now - started) * 1000)
        if samples.count > 60 { samples.removeFirst() }
        return true
    }
    func expired(now: TimeInterval) -> Bool { pending.map { now - $0.1 > 3 } ?? false }
    // A diagnostic reply deadline is not proof that the peer died when valid
    // input still arrives or our own run loop could not dispatch callbacks.
    mutating func discardExpiredAfterLocalDelay(now: TimeInterval, lastAuthenticated: TimeInterval, schedulerDelay: TimeInterval) -> Bool {
        guard expired(now: now), now >= lastAuthenticated,
              now - lastAuthenticated < 3 || schedulerDelay >= 2 else { return false }
        pending = nil
        return true
    }
    mutating func queueWait(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        queueSamples.append(ms); if queueSamples.count > 120 { queueSamples.removeFirst() }
    }
    var snapshot: InputHealth? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let jitter = zip(samples, samples.dropFirst()).map { abs($0 - $1) }
        return InputHealth(samples: samples.count, rttMS: samples.last!,
            p95MS: sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            jitterMS: jitter.isEmpty ? 0 : jitter.reduce(0, +) / Double(jitter.count), queueMaxMS: queueSamples.max() ?? 0)
    }
}

struct MotionCadence {
    private var previous: (sent: Double, arrived: Double)?
    private var sentIntervals: [Double] = []
    private var arrivalIntervals: [Double] = []
    private var excessIntervals: [Double] = []
    private(set) var bursts = 0
    var count: Int { sentIntervals.count }
    // Compare intervals on each Mac's own monotonic clock. Clock origins need
    // not agree. This measures delivery jitter, never absolute one-way latency.
    mutating func record(sent: Double?, arrived: Double) {
        guard let sent, sent.isFinite, sent >= 0, arrived.isFinite else { previous = nil; return }
        defer { previous = (sent, arrived) }
        guard let previous else { return }
        let source = sent - previous.sent, arrival = arrived - previous.arrived
        // Ignore deliberate pauses, changed clock origins, and invalid ordering.
        guard source > 0, source <= 0.1, arrival >= 0 else { return }
        sentIntervals.append(source * 1000); arrivalIntervals.append(arrival * 1000)
        excessIntervals.append(max(0, arrival - source) * 1000)
        if source >= 0.004 && arrival < 0.002 { bursts += 1 }
        if sentIntervals.count > 240 {
            sentIntervals.removeFirst(); arrivalIntervals.removeFirst(); excessIntervals.removeFirst()
        }
    }
    private func p95(_ values: [Double]) -> Int {
        guard !values.isEmpty else { return 0 }
        return Int(values.sorted()[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)].rounded())
    }
    var sourceP95: Int { p95(sentIntervals) }
    var arrivalP95: Int { p95(arrivalIntervals) }
    var excessP95: Int { p95(excessIntervals) }
    var label: String? {
        guard count >= 10 else { return nil }
        return "마우스 간격 p95 · 보냄 \(sourceP95)ms / 받음 \(arrivalP95)ms · 추가 흔들림 \(excessP95)ms"
    }
}
