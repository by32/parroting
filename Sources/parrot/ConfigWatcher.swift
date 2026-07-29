import Foundation

/// Watches the config file for external edits and calls `onChange` with the
/// reloaded `Config`. Atomic writes (temp file + rename) replace the inode, so
/// the watcher reopens the file descriptor after each event rather than holding
/// a stale one.
final class ConfigWatcher {
    private let url: URL
    private let queue = DispatchQueue(label: "parrot.config-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private var debounce: DispatchWorkItem?
    private let onChange: @Sendable (Config) -> Void

    init(url: URL, onChange: @escaping @Sendable (Config) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        reopen()
    }

    func stop() {
        source?.cancel()
        source = nil
        debounce?.cancel()
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func reopen() {
        source?.cancel()
        if fd >= 0 { close(fd); fd = -1 }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        source.resume()
        self.source = source
    }

    /// Coalesces rapid events (an atomic write can fire two) and reopens the
    /// descriptor before notifying, so the callback reads the new file content
    /// rather than a partially-written buffer.
    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reopen()
            do {
                let config = try Config.load(from: self.url)
                self.onChange(config)
            } catch {
                FileHandle.standardError.write(Data(
                    "config file changed but failed to parse: \(error)\n".utf8
                ))
            }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
