import CoreServices
import Foundation

/// Reports changed directories under the watched folders (FSEvents), coalesced by `latency`.
@MainActor
final class FileWatcher {
    private final class Callback {
        let handler: @MainActor ([String]) -> Void
        init(_ handler: @escaping @MainActor ([String]) -> Void) { self.handler = handler }
    }

    /// Only touched on the main actor, and in deinit once nothing else can.
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    init(urls: [URL], latency: TimeInterval = 0.3, onChange: @escaping @MainActor ([String]) -> Void) {
        // The stream retains the callback, so an event delivered while it is being torn down
        // never reaches a freed object. The local keeps it alive until the stream has retained it.
        let callback = Callback(onChange)
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(callback).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<Callback>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Callback>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let paths = urls.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { callback.handler(Array(changed.prefix(count))) }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        withExtendedLifetime(callback) {}
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            Self.tearDown(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        Self.tearDown(stream)
        self.stream = nil
    }

    private nonisolated static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
