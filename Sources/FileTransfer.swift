import Foundation
import CryptoKit
import Darwin

// Keep the chosen directory open so a later rename or symlink cannot redirect a drop.
final class ReceiveDirectory {
    let fd: Int32
    init(_ url: URL) throws {
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ClipError.invalid(ui("Couldn’t save to this folder.")) }
    }
    deinit { close(fd) }
    func matches(_ url: URL) -> Bool {
        var chosen = stat(), current = stat()
        return fstat(fd, &chosen) == 0 && stat(url.path, &current) == 0 &&
            chosen.st_dev == current.st_dev && chosen.st_ino == current.st_ino
    }
}

// Created only after the recipient chooses a path. No sender path is ever used.
final class ReceivedFile {
    let destination: URL
    private let directory: ReceiveDirectory
    private let temporary: String
    private let handle: FileHandle
    private var committed = false
    private(set) var count: Int64 = 0
    private var hash = SHA256()
    init(destination: URL, directory approved: ReceiveDirectory? = nil) throws {
        guard destination.isFileURL, FilePacket.safeName(destination.lastPathComponent) else { throw ClipError.invalid(ui("Choose a valid filename.")) }
        let parent = destination.deletingLastPathComponent()
        directory = try approved ?? ReceiveDirectory(parent)
        guard directory.matches(parent) else { throw ClipError.invalid(ui("Couldn’t save to this folder.")) }
        var existing = stat()
        guard fstatat(directory.fd, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else {
            throw ClipError.invalid(ui("The name is taken or the folder is unavailable. Choose another name or location."))
        }
        self.destination = destination
        temporary = ".nearclip-" + UUID().uuidString + ".part"
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ClipError.invalid(ui("Couldn’t save to this folder.")) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    deinit { try? handle.close(); if !committed { _ = unlinkat(directory.fd, temporary, 0) } }
    func append(_ data: Data, offset: Int64, size: Int64) throws {
        guard offset == count, !data.isEmpty, data.count <= FilePacket.chunkSize, count + Int64(data.count) <= size else { throw ClipError.invalid(ui("Unexpected file size or transfer order.")) }
        try handle.write(contentsOf: data); hash.update(data: data); count += Int64(data.count)
    }
    func finish(size: Int64, digest: Data) throws {
        guard count == size, Data(hash.finalize()) == digest else { throw ClipError.invalid(ui("File verification failed. Send the file again.")) }
        // Preserve Gatekeeper's first-open checks and never restore sender executable bits.
        let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";NearClip;" + UUID().uuidString
        let marked = quarantine.withCString { fsetxattr(handle.fileDescriptor, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        guard marked == 0, fchmod(handle.fileDescriptor, S_IRUSR | S_IWUSR) == 0 else { throw ClipError.invalid(ui("Couldn’t apply the file’s security attributes.")) }
        try handle.synchronize()
        // A hard link creates the final name atomically and fails if any item already exists.
        guard linkat(directory.fd, temporary, directory.fd, destination.lastPathComponent, 0) == 0 else { throw ClipError.invalid(errno == EEXIST ? ui("A file with this name already exists. Choose another name.") : ui("Couldn’t save the file safely here. Choose another folder.")) }
        try? handle.close(); _ = unlinkat(directory.fd, temporary, 0); committed = true
    }
}

final class FileTransferWorker {
    private final class Outgoing {
        let offer: FilePacket
        let peer: String
        let handle: FileHandle
        var hash = SHA256()
        var offset: Int64 = 0
        var pendingOffsets: [Int64] = []
        var chunkWindow = 1
        var finishing = false
        init(url: URL, peer: String, id: UUID) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ClipError.invalid(ui("Couldn’t open the file.")) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= FilePacket.maxSize, FilePacket.safeName(url.lastPathComponent) else {
                try? handle.close(); throw ClipError.invalid(ui("Send one regular file up to 2 GiB. Compress folders first."))
            }
            self.handle = handle; self.peer = peer
            offer = FilePacket(kind: .offer, id: id, name: url.lastPathComponent, size: info.st_size)
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
    func offer(url: URL, to peer: String, id: UUID = UUID(), preparePreview: Bool = false) throws {
        guard !busy else { throw ClipError.invalid(ui("Finish or cancel the current file transfer first.")) }
        let job = try Outgoing(url: url, peer: peer, id: id); outgoing = job; updated = Date()
        status(ui("Waiting for the recipient · ") + (job.offer.name ?? ui("File")))
        var offer = job.offer
        if preparePreview, FilePacket.canPrepareImage(name: offer.name, size: offer.size), let size = offer.size {
            do {
                if let bytes = try job.handle.read(upToCount: Int(size)), let thumb = PreparedDragImage.thumbnail(bytes) {
                    offer.previewPNG = PreparedDragImage.encodePreview(thumb)
                }
                try job.handle.seek(toOffset: 0)
            } catch { fail(error.localizedDescription); return }
        }
        emit(offer, to: peer)
    }
    func accept(id: UUID, destination: URL, directory: ReceiveDirectory? = nil) {
        guard let job = incoming, job.offer.id == id, job.writer == nil else { return }
        do {
            job.writer = try ReceivedFile(destination: destination, directory: directory); updated = Date()
            status(ui("Receiving · ") + (job.offer.name ?? ui("File")), progress: 0)
            emit(FilePacket(kind: .accept, id: id, chunkWindow: FilePacket.maxChunkWindow), to: job.peer)
        } catch { fail(error.localizedDescription) }
    }
    func decline(id: UUID) { if activeID == id { cancel() } }
    func disconnected() { if busy { fail(ui("Transfer cancelled because the connection closed."), notify: false) } }
    func receive(_ message: FilePacket, from peer: String) {
        do {
            try message.validate()
            if message.kind == .offer {
                guard !busy else { emit(FilePacket(kind: .cancel, id: message.id), to: peer); return }
                incoming = Incoming(offer: message, peer: peer); updated = Date()
                status(ui("Review incoming file · ") + (message.name ?? ui("File")))
                onOffer?(peer, message); return
            }
            guard peer == self.peer, message.id == activeID else { return }
            updated = Date()
            switch message.kind {
            case .accept:
                guard let job = outgoing, job.offset == 0, !job.finishing else { throw ClipError.invalid(ui("Unexpected file acceptance.")) }
                job.chunkWindow = message.chunkWindow ?? 1
                try sendChunks(job)
            case .ack:
                guard let job = outgoing, let first = job.pendingOffsets.first, message.offset == first else { throw ClipError.invalid(ui("Invalid file receipt.")) }
                job.pendingOffsets.removeFirst(); try sendChunks(job)
            case .chunk:
                guard let job = incoming, let writer = job.writer, let bytes = message.bytes, let offset = message.offset else { throw ClipError.invalid(ui("Accept the file before saving it.")) }
                try writer.append(bytes, offset: offset, size: job.offer.size!)
                status(ui("Receiving · ") + job.offer.name!, progress: Double(writer.count) / Double(max(1, job.offer.size!)))
                emit(FilePacket(kind: .ack, id: message.id, offset: writer.count), to: peer)
            case .finish:
                guard let job = incoming, let writer = job.writer, let digest = message.digest else { throw ClipError.invalid(ui("This file hasn’t been accepted.")) }
                try writer.finish(size: job.offer.size!, digest: digest)
                let destination = writer.destination; incoming = nil
                emit(FilePacket(kind: .complete, id: message.id), to: peer)
                status(ui("File saved · ") + destination.lastPathComponent, progress: 1); onComplete?(destination)
            case .complete:
                guard outgoing?.finishing == true else { throw ClipError.invalid(ui("Unexpected transfer completion.")) }
                outgoing = nil; status(ui("File saved on the other Mac."), progress: 1); onComplete?(nil)
            case .cancel: fail(ui("Transfer cancelled."), notify: false)
            case .offer: break
            }
        } catch { if self.peer == peer, activeID == message.id { fail(error.localizedDescription) } }
    }
    private func sendChunks(_ job: Outgoing) throws {
        let size = job.offer.size!
        while outgoing === job && job.pendingOffsets.count < job.chunkWindow && job.offset < size {
            let offset = job.offset
            let data = try job.handle.read(upToCount: min(FilePacket.chunkSize, Int(size - offset))) ?? Data()
            guard !data.isEmpty else { throw ClipError.invalid(ui("The file changed during transfer. Send it again.")) }
            job.offset += Int64(data.count); job.hash.update(data: data)
            job.pendingOffsets.append(job.offset)
            status(ui("Sending · ") + (job.offer.name ?? ui("File")), progress: Double(job.offset) / Double(size))
            emit(FilePacket(kind: .chunk, id: job.offer.id, offset: offset, bytes: data), to: job.peer)
        }
        guard outgoing === job, job.offset == size, job.pendingOffsets.isEmpty, !job.finishing else { return }
        guard (try job.handle.read(upToCount: 1) ?? Data()).isEmpty else { throw ClipError.invalid(ui("The file size changed. Send it again.")) }
        job.finishing = true
        emit(FilePacket(kind: .finish, id: job.offer.id, digest: Data(job.hash.finalize())), to: job.peer)
    }
    private func emit(_ packet: FilePacket, to peer: String) {
        guard let send else { fail(ui("Connect to a Mac to send files."), notify: false); return }
        send(peer, packet) { [weak self] success in
            guard let self, !success, self.activeID == packet.id else { return }
            self.fail(ui("Couldn’t send the file. Check the connection."), notify: false)
        }
    }
    func cancel() { if busy { fail(ui("File transfer cancelled.")) } }
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
        let waiting = incoming?.writer == nil && incoming != nil || outgoing?.offset == 0 && outgoing?.finishing == false
        if busy, now.timeIntervalSince(updated) > (waiting ? 120 : 30) { fail(ui("Transfer cancelled after a timeout.")) }
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
    func offer(url: URL, to peer: String, id: UUID = UUID(), keeping source: DragSourceFile? = nil, preparePreview: Bool = false) throws {
        guard !busy else { throw ClipError.invalid(ui("Finish the current file transfer first.")) }
        busy = true; onStatus?(ui("Preparing file…"), nil, true)
        queue.async { [self] in
            do { try withExtendedLifetime(source) { try worker.offer(url: url, to: peer, id: id, preparePreview: preparePreview) } }
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
    func accept(id: UUID, destination: URL, directory: ReceiveDirectory? = nil) { queue.async { [self] in worker.accept(id: id, destination: destination, directory: directory) } }
    func decline(id: UUID) { queue.async { [self] in worker.decline(id: id) } }
    func cancel() { queue.async { [self] in worker.cancel() } }
    func disconnected() { queue.async { [self] in worker.disconnected() } }
    func checkTimeout(now: Date = Date()) { queue.async { [self] in worker.checkTimeout(now: now) } }
    func stop() { timer?.invalidate(); timer = nil; queue.sync { worker.cancel() } }
}
