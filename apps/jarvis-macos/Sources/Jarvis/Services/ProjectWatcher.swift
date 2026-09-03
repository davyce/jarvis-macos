import CoreServices
import Foundation

/// Watches a project's working tree for filesystem changes and calls back
/// (debounced) so Jarvis can refresh its Git/build context without a manual
/// "Actualiser" click. Only ever watches the currently focused project.
final class ProjectWatcher: @unchecked Sendable {
    /// Subtrees that legitimately churn on their own (git internals during a
    /// `git status`/`git log`, build output, dependency caches) and must never
    /// retrigger a refresh, or a refresh -> git status -> .git write -> refresh
    /// feedback loop pegs the CPU forever.
    private static let excludedSubpaths = [".git", "node_modules", ".build", "DerivedData", "build"]

    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.adansonia.jarvis.project-watcher")
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let pathsToWatch = [path] as CFArray

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue().scheduleCallback()
        }

        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        stream = streamRef

        let exclusions = Self.excludedSubpaths.map { path + "/" + $0 } as CFArray
        FSEventStreamSetExclusionPaths(streamRef, exclusions)

        FSEventStreamSetDispatchQueue(streamRef, queue)
        FSEventStreamStart(streamRef)
    }

    func stop() {
        guard let streamRef = stream else { return }
        FSEventStreamStop(streamRef)
        FSEventStreamInvalidate(streamRef)
        FSEventStreamRelease(streamRef)
        stream = nil
    }

    private func scheduleCallback() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onChange] in onChange() }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    deinit {
        stop()
    }
}
