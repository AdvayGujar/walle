import Darwin
import Foundation

/// A non-blocking exclusive lock, so only one picker is ever on screen.
///
/// Without this, two hotkey presses — or a duplicate binding in skhdrc — stack two
/// full-screen overlays, and dismissing the top one reveals the other underneath.
public enum SingleInstance {

    public struct Lock: @unchecked Sendable {
        public let fileDescriptor: Int32
        public let url: URL
    }

    /// Takes the lock, or returns nil when another instance already holds it.
    public static func acquire(at url: URL, fileManager: FileManager = .default) -> Lock? {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // The lock file could not be created at all. Fail open: a picker that refuses to
            // start because it cannot write a lock file is much worse than the duplicate
            // overlay this guard exists to prevent.
            return Lock(fileDescriptor: -1, url: url)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // Record the pid so a later instance can ask us to close rather than giving up.
        ftruncate(fd, 0)
        let text = String(getpid()) + "\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        return Lock(fileDescriptor: fd, url: url)
    }

    /// The pid recorded by the instance currently holding the lock, if any.
    public static func holderPid(at url: URL) -> pid_t? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Asks the running picker to dismiss itself, making the hotkey a toggle.
    @discardableResult
    public static func askHolderToDismiss(at url: URL) -> Bool {
        guard let pid = holderPid(at: url), pid > 1 else { return false }
        return kill(pid, SIGUSR1) == 0
    }

    public static func release(_ lock: Lock) {
        guard lock.fileDescriptor >= 0 else { return }
        flock(lock.fileDescriptor, LOCK_UN)
        close(lock.fileDescriptor)
    }
}
