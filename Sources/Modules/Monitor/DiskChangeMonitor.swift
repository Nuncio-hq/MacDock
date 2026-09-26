import Foundation
import CoreServices

/// Watches a scanned subtree for filesystem changes. FSEvents reports changes
/// recursively without keeping every directory open.
final class DiskChangeMonitor: @unchecked Sendable {
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "hq.nuncio.MacDock.disk-changes")
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<DiskChangeMonitor>
                .fromOpaque(info)
                .takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if count > 0 { monitor.handler(changed) }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
