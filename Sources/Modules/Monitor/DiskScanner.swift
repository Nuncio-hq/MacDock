import Foundation
import Darwin

/// One node in the scanned filesystem tree.
struct DiskNode: Sendable, Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    var size: UInt64          // allocated bytes, descendants included
    var ownSize: UInt64 = 0   // files owned directly by this node
    var isDirectory: Bool
    var restricted: Bool      // we could not read into it (permissions)
    var children: [DiskNode]?

    static func == (l: DiskNode, r: DiskNode) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ScanProgress: Sendable {
    var files: Int = 0
    var currentPath: String = ""
}

/// Fast recursive directory scanner built on getattrlistbulk(2) — the same
/// bulk-attribute API DaisyDisk-style tools use instead of FileManager or
/// Spotlight (which skip many locations).
final class DiskScanner: Sendable {
    private let progress: @Sendable (ScanProgress) -> Void
    private let state = ScanState()
    private let limiter = PermitPool(limit: 32)

    init(progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.progress = progress
    }

    /// Firmlinked/mounted subtrees we must not double-count when scanning "/".
    private static let rootSkipList: Set<String> = [
        "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM",
        "/System/Volumes/Update", "/dev", "/net", "/home",
    ]

    func scan(root: String) async -> DiskNode {
        let skip: Set<String> = root == "/" ? Self.rootSkipList : []
        let rootName = root == "/" ? "Macintosh HD" : URL(fileURLWithPath: root).lastPathComponent
        return await scanDir(path: root, name: rootName, skipList: skip)
    }

    private func scanDir(path: String, name: String, skipList: Set<String>) async -> DiskNode {
        var node = DiskNode(path: path, name: name, size: 0,
                            isDirectory: true, restricted: false, children: [])
        if Task.isCancelled { return node }
        await limiter.acquire()
        let entries = try? bulkList(path)
        await limiter.release()
        guard let entries else {
            node.restricted = true
            return node
        }

        var subdirs: [(path: String, name: String)] = []
        for e in entries {
            if e.isDir {
                if e.isMountPoint || skipList.contains(e.path) { continue }
                subdirs.append((e.path, e.name))
                node.ownSize += e.alloc
            } else {
                node.ownSize += effectiveSize(e)
            }
        }
        node.size = node.ownSize

        if !subdirs.isEmpty {
            node.children = await withTaskGroup(of: DiskNode.self) { group in
                for sub in subdirs {
                    group.addTask {
                        await self.scanDir(path: sub.path, name: sub.name, skipList: skipList)
                    }
                }
                var kids: [DiskNode] = []
                for await child in group {
                    kids.append(child)
                }
                return kids.sorted { $0.size > $1.size }
            }
            for child in node.children ?? [] { node.size += child.size }
        }
        return node
    }

    // MARK: - getattrlistbulk

    private struct Entry: Sendable {
        var path: String
        var name: String
        var isDir: Bool
        var isMountPoint: Bool
        var alloc: UInt64
        var fileID: UInt64
        var linkCount: UInt32
    }

    private func effectiveSize(_ e: Entry) -> UInt64 {
        // Count a multiply-linked file once.
        if e.linkCount > 1 && !state.insertInode(e.fileID) { return 0 }
        let n = state.bump()
        if n % 512 == 0 { progress(ScanProgress(files: n, currentPath: e.path)) }
        return e.alloc
    }

    private static func makeAttrSpec() -> attrlist {
        var a = attrlist()
        a.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ERROR)
        a.dirattr = UInt32(ATTR_DIR_ENTRYCOUNT) | UInt32(ATTR_DIR_MOUNTSTATUS) | UInt32(ATTR_DIR_ALLOCSIZE)
        a.fileattr = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH)
        return a
    }

    private static let FSOBJ_VDIR: UInt32 = 2   // fsobj_type_t VDIR

    private func bulkList(_ path: String) throws -> [Entry] {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var spec = Self.makeAttrSpec()
        var out: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &spec, buf, bufSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if count == 0 { break }

            var p = buf
            for _ in 0..<count {
                let record = p
                let len = Int(record.loadUnaligned(as: UInt32.self))
                var q = record + 4
                let returned = q.loadUnaligned(as: attribute_set_t.self)
                q += MemoryLayout<attribute_set_t>.size
                p += len

                var entry = Entry(path: "", name: "", isDir: false,
                                  isMountPoint: false, alloc: 0, fileID: 0, linkCount: 0)
                var failed = false

                // commonattr fields in ascending bit order
                if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
                    let ref = q.loadUnaligned(as: attrreference_t.self)
                    let namePtr = q.advanced(by: Int(ref.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self)
                    var nameLen = Int(ref.attr_length)
                    if nameLen > 0 && namePtr[nameLen - 1] == 0 { nameLen -= 1 }
                    entry.name = String(decoding: UnsafeBufferPointer(
                        start: UnsafePointer<UInt8>(OpaquePointer(namePtr)),
                        count: nameLen), as: UTF8.self)
                    q += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                    let t = q.loadUnaligned(as: UInt32.self)
                    entry.isDir = t == Self.FSOBJ_VDIR
                    q += MemoryLayout<UInt32>.size
                }
                if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 {
                    entry.fileID = q.loadUnaligned(as: UInt64.self)
                    q += MemoryLayout<UInt64>.size
                }
                if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
                    let err = q.loadUnaligned(as: UInt32.self)
                    q += MemoryLayout<UInt32>.size
                    if err != 0 { failed = true }
                }

                // dirattr OR fileattr depending on object type
                if entry.isDir {
                    if returned.dirattr & UInt32(ATTR_DIR_ENTRYCOUNT) != 0 {
                        q += MemoryLayout<UInt64>.size
                    }
                    if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
                        let m = q.loadUnaligned(as: UInt32.self)
                        entry.isMountPoint = (m & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0
                        q += MemoryLayout<UInt32>.size
                    }
                    if returned.dirattr & UInt32(ATTR_DIR_ALLOCSIZE) != 0 {
                        entry.alloc = q.loadUnaligned(as: UInt64.self)
                        q += MemoryLayout<UInt64>.size
                    }
                } else {
                    if returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
                        entry.linkCount = q.loadUnaligned(as: UInt32.self)
                        q += MemoryLayout<UInt32>.size
                    }
                    if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
                        entry.alloc = q.loadUnaligned(as: UInt64.self)
                        q += MemoryLayout<UInt64>.size
                    }
                    if returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0 {
                        q += MemoryLayout<UInt64>.size
                    }
                }

                if failed || entry.name.isEmpty { continue }
                entry.path = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
                out.append(entry)
            }
        }
        return out
    }
}

// MARK: - helpers

/// Lock-based counters — called once per file, actor hops were the bottleneck.
private final class ScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var inodes = Set<UInt64>()

    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        files += 1
        return files
    }

    /// Returns false if the inode was already counted.
    func insertInode(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inodes.insert(id).inserted
    }
}

/// Bounds concurrent bulkList calls — each holds an open fd and a 256KB
/// buffer, so unlimited recursion would balloon memory on big trees.
private actor PermitPool {
    private let limit: Int
    private var taken = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if taken < limit { taken += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            taken -= 1
        }
    }
}
