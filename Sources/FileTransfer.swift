import Foundation
import CryptoKit
import Darwin

// Created only after the recipient chooses a path. No sender path is ever used.
final class ReceivedFile {
    let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var committed = false
    private(set) var count: Int64 = 0
    private var hash = SHA256()
    init(destination: URL) throws {
        guard destination.isFileURL, FilePacket.safeName(destination.lastPathComponent) else { throw ClipError.invalid("저장할 파일 이름을 확인해 주세요.") }
        var existing = stat()
        guard lstat(destination.path, &existing) != 0 && errno == ENOENT else {
            throw ClipError.invalid("같은 이름의 파일이 있거나 저장 위치에 접근할 수 없어요. 다른 이름을 선택해 주세요.")
        }
        self.destination = destination
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".nearclip-" + UUID().uuidString + ".part")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ClipError.invalid("선택한 폴더에 저장할 수 없어요.") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    deinit { try? handle.close(); if !committed { try? FileManager.default.removeItem(at: temporary) } }
    func append(_ data: Data, offset: Int64, size: Int64) throws {
        guard offset == count, !data.isEmpty, data.count <= FilePacket.chunkSize, count + Int64(data.count) <= size else { throw ClipError.invalid("파일 전송 순서나 크기가 맞지 않아요.") }
        try handle.write(contentsOf: data); hash.update(data: data); count += Int64(data.count)
    }
    func finish(size: Int64, digest: Data) throws {
        guard count == size, Data(hash.finalize()) == digest else { throw ClipError.invalid("파일 검증에 실패했어요. 다시 보내주세요.") }
        // Preserve Gatekeeper's first-open checks and never restore sender executable bits.
        let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";NearClip;" + UUID().uuidString
        let marked = quarantine.withCString { fsetxattr(handle.fileDescriptor, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        guard marked == 0, fchmod(handle.fileDescriptor, S_IRUSR | S_IWUSR) == 0 else { throw ClipError.invalid("파일의 안전한 저장 속성을 설정하지 못했어요.") }
        try handle.synchronize()
        // A hard link creates the final name atomically and fails if any item already exists.
        guard link(temporary.path, destination.path) == 0 else { throw ClipError.invalid(errno == EEXIST ? "같은 이름의 파일이 있어요. 다른 이름으로 다시 받아주세요." : "이 폴더에 파일을 안전하게 저장할 수 없어요. 다른 폴더로 다시 받아주세요.") }
        try? handle.close(); try? FileManager.default.removeItem(at: temporary); committed = true
    }
}

final class FileTransferWorker {
    private final class Outgoing {
        let offer: FilePacket
        let peer: String
        let handle: FileHandle
        var hash = SHA256()
        var offset: Int64 = 0
        var awaitingAck = false
        var finishing = false
        init(url: URL, peer: String) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ClipError.invalid("파일을 열 수 없어요.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= FilePacket.maxSize, FilePacket.safeName(url.lastPathComponent) else {
                try? handle.close(); throw ClipError.invalid("일반 파일 하나를 2GB까지 보낼 수 있어요. 폴더는 ZIP으로 압축해 주세요.")
            }
            self.handle = handle; self.peer = peer
            offer = FilePacket(kind: .offer, id: UUID(), name: url.lastPathComponent, size: info.st_size)
        }
        deinit { try? handle.close() }
    }
    private final class Incoming {
        let offer: FilePacket
        let peer: String
        var writer: ReceivedFile?
        init(offer: FilePacket, peer: String) { self.offer = offer; self.peer = peer }
    }
    private var outgoing: Outgoing?
    private var incoming: Incoming?
    private var updated = Date()
    private var lastProgressUpdate = Date.distantPast
    var send: ((String, FilePacket, @escaping (Bool) -> Void) -> Void)?
    var onOffer: ((String, FilePacket) -> Void)?
    var onStatus: ((String, Double?, Bool) -> Void)?
    var onComplete: ((URL?) -> Void)?
    var busy: Bool { outgoing != nil || incoming != nil }
    var activeID: UUID? { outgoing?.offer.id ?? incoming?.offer.id }
    private var peer: String? { outgoing?.peer ?? incoming?.peer }
    func stop() { cancel() }
    func offer(url: URL, to peer: String) throws {
        guard !busy else { throw ClipError.invalid("진행 중인 파일 전송을 먼저 마치거나 취소해 주세요.") }
        let job = try Outgoing(url: url, peer: peer); outgoing = job; updated = Date()
        status("상대의 수락을 기다리고 있어요 · " + (job.offer.name ?? "파일"))
        emit(job.offer, to: peer)
    }
    func accept(id: UUID, destination: URL) {
        guard let job = incoming, job.offer.id == id, job.writer == nil else { return }
        do {
            job.writer = try ReceivedFile(destination: destination); updated = Date()
            status("파일 받는 중 · " + (job.offer.name ?? "파일"), progress: 0)
            emit(FilePacket(kind: .accept, id: id), to: job.peer)
        } catch { fail(error.localizedDescription) }
    }
    func decline(id: UUID) { if activeID == id { cancel() } }
    func disconnected() { if busy { fail("연결이 끊겨 파일 전송을 취소했어요.", notify: false) } }
    func receive(_ message: FilePacket, from peer: String) {
        do {
            try message.validate()
            if message.kind == .offer {
                guard !busy else { emit(FilePacket(kind: .cancel, id: message.id), to: peer); return }
                incoming = Incoming(offer: message, peer: peer); updated = Date()
                status("받을 파일을 확인해 주세요 · " + (message.name ?? "파일"))
                onOffer?(peer, message); return
            }
            guard peer == self.peer, message.id == activeID else { return }
            updated = Date()
            switch message.kind {
            case .accept:
                guard let job = outgoing, !job.awaitingAck, job.offset == 0, !job.finishing else { throw ClipError.invalid("파일 수락 순서가 맞지 않아요.") }
                try nextChunk(job)
            case .ack:
                guard let job = outgoing, job.awaitingAck, !job.finishing, message.offset == job.offset else { throw ClipError.invalid("파일 수신 확인이 맞지 않아요.") }
                job.awaitingAck = false; try nextChunk(job)
            case .chunk:
                guard let job = incoming, let writer = job.writer, let bytes = message.bytes, let offset = message.offset else { throw ClipError.invalid("수락하지 않은 파일은 저장하지 않아요.") }
                try writer.append(bytes, offset: offset, size: job.offer.size!)
                status("파일 받는 중 · " + job.offer.name!, progress: Double(writer.count) / Double(max(1, job.offer.size!)))
                emit(FilePacket(kind: .ack, id: message.id, offset: writer.count), to: peer)
            case .finish:
                guard let job = incoming, let writer = job.writer, let digest = message.digest else { throw ClipError.invalid("수락하지 않은 파일이에요.") }
                try writer.finish(size: job.offer.size!, digest: digest)
                let destination = writer.destination; incoming = nil
                emit(FilePacket(kind: .complete, id: message.id), to: peer)
                status("파일을 저장했어요 · " + destination.lastPathComponent, progress: 1); onComplete?(destination)
            case .complete:
                guard outgoing?.finishing == true else { throw ClipError.invalid("파일 완료 순서가 맞지 않아요.") }
                outgoing = nil; status("상대 Mac에 파일이 저장됐어요.", progress: 1); onComplete?(nil)
            case .cancel: fail("파일 전송이 취소됐어요.", notify: false)
            case .offer: break
            }
        } catch { if self.peer == peer, activeID == message.id { fail(error.localizedDescription) } }
    }
    private func nextChunk(_ job: Outgoing) throws {
        let remaining = job.offer.size! - job.offset
        if remaining == 0 {
            guard (try job.handle.read(upToCount: 1) ?? Data()).isEmpty else { throw ClipError.invalid("전송 중 파일 크기가 바뀌었어요. 다시 보내주세요.") }
            job.finishing = true
            emit(FilePacket(kind: .finish, id: job.offer.id, digest: Data(job.hash.finalize())), to: job.peer)
            return
        }
        let data = try job.handle.read(upToCount: min(FilePacket.chunkSize, Int(remaining))) ?? Data()
        guard !data.isEmpty else { throw ClipError.invalid("전송 중 파일이 변경됐어요. 다시 보내주세요.") }
        let offset = job.offset; job.offset += Int64(data.count); job.hash.update(data: data); job.awaitingAck = true
        status("파일 보내는 중 · " + job.offer.name!, progress: Double(job.offset) / Double(max(1, job.offer.size!)))
        emit(FilePacket(kind: .chunk, id: job.offer.id, offset: offset, bytes: data), to: job.peer)
    }
    private func emit(_ packet: FilePacket, to peer: String) {
        guard let send else { fail("파일 전송 연결이 없어요.", notify: false); return }
        send(peer, packet) { [weak self] success in
            guard let self, !success, self.activeID == packet.id else { return }
            self.fail("파일을 보내지 못했어요. 연결을 확인해 주세요.", notify: false)
        }
    }
    func cancel() { if busy { fail("파일 전송을 취소했어요.") } }
    private func fail(_ message: String, notify: Bool = true) {
        let id = activeID, peer = self.peer; outgoing = nil; incoming = nil
        if notify, let id, let peer { emit(FilePacket(kind: .cancel, id: id), to: peer) }
        status(message)
    }
    private func status(_ text: String, progress: Double? = nil) {
        if let progress, busy, progress > 0, progress < 1 {
            guard Date().timeIntervalSince(lastProgressUpdate) >= 0.1 else { return }
            lastProgressUpdate = Date()
        }
        onStatus?(text, progress, busy)
    }
    func checkTimeout(now: Date = Date()) {
        let waiting = incoming?.writer == nil && incoming != nil || outgoing?.offset == 0 && outgoing?.awaitingAck == false
        if busy, now.timeIntervalSince(updated) > (waiting ? 120 : 30) { fail("응답 시간이 지나 파일 전송을 취소했어요.") }
    }
}

// File I/O and hashing stay off the input event-tap run loop. Only UI/network
// callbacks cross to main; every worker state transition is serialized.
final class FileTransfer {
    private let queue = DispatchQueue(label: "dev.nearclip.files", qos: .utility)
    private let worker = FileTransferWorker()
    private var pendingPackets = 0
    private var overloaded = false
    private var timer: Timer?
    private(set) var busy = false
    private(set) var activeID: UUID?
    var send: ((String, FilePacket, @escaping (Bool) -> Void) -> Void)?
    var onOffer: ((String, FilePacket) -> Void)?
    var onStatus: ((String, Double?, Bool) -> Void)?
    var onComplete: ((URL?) -> Void)?
    init() {
        worker.send = { [weak self] peer, packet, reply in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let send = self.send else { self.queue.async { reply(false) }; return }
                send(peer, packet) { [weak self] success in self?.queue.async { reply(success) } }
            }
        }
        worker.onStatus = { [weak self] text, progress, busy in
            guard let self else { return }; let id = self.worker.activeID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = busy; self.activeID = id; if !busy { self.overloaded = false }; self.onStatus?(text, progress, busy)
            }
        }
        worker.onOffer = { [weak self] peer, offer in DispatchQueue.main.async { self?.onOffer?(peer, offer) } }
        worker.onComplete = { [weak self] url in DispatchQueue.main.async { self?.onComplete?(url) } }
    }
    func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkTimeout() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func offer(url: URL, to peer: String) throws {
        guard !busy else { throw ClipError.invalid("진행 중인 파일 전송을 먼저 마쳐주세요.") }
        busy = true; onStatus?("파일을 준비하고 있어요.", nil, true)
        queue.async { [self] in
            do { try worker.offer(url: url, to: peer) }
            catch { worker.onStatus?(error.localizedDescription, nil, worker.busy) }
        }
    }
    func receive(_ packet: FilePacket, from peer: String) {
        guard !overloaded else { return }
        guard pendingPackets < 8 else { overloaded = true; disconnected(); return }
        pendingPackets += 1
        queue.async { [self] in
            worker.receive(packet, from: peer)
            DispatchQueue.main.async { [weak self] in self?.pendingPackets -= 1 }
        }
    }
    func accept(id: UUID, destination: URL) { queue.async { [self] in worker.accept(id: id, destination: destination) } }
    func decline(id: UUID) { queue.async { [self] in worker.decline(id: id) } }
    func cancel() { queue.async { [self] in worker.cancel() } }
    func disconnected() { queue.async { [self] in worker.disconnected() } }
    func checkTimeout(now: Date = Date()) { queue.async { [self] in worker.checkTimeout(now: now) } }
    func stop() { timer?.invalidate(); timer = nil; queue.sync { worker.cancel() } }
}
