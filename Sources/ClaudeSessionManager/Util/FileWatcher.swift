import Foundation

/// Watches a single file for changes (appends, rewrites, replacement) and calls
/// `onChange` on the main queue, debounced. Used to live-reload a session
/// transcript while it's being written by a running `claude` process.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
    }

    private func start() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            // Editors/tools often replace the file (rename/delete) — re-arm on a
            // fresh descriptor so we keep tracking the new inode.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.rearm()
            }
            self.scheduleChange()
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
        }
        source = src
        src.resume()
    }

    private func rearm() {
        source?.cancel()
        source = nil
        // Small delay so the replacement file is in place before we re-open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.start()
        }
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
