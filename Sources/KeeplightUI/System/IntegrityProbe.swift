import Darwin
import Foundation

/// Self-measurement for Settings › About: how many IP sockets this process has open right now.
/// Read through libproc (`proc_pidinfo(PROC_PIDLISTFDS)`, then `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`
/// per socket descriptor). No networking code: nothing is opened, only counted. A handful of
/// syscalls, run when the About tab appears; no timer.
enum IntegrityProbe {
    /// One open file descriptor as the kernel lists it: its type and, for a socket, its address
    /// family (nil when the socket could not be inspected).
    struct Descriptor: Equatable, Sendable {
        var type: UInt32
        var family: Int32?

        static func socket(_ family: Int32?) -> Descriptor { Descriptor(type: UInt32(PROX_FDTYPE_SOCKET), family: family) }
        static func file() -> Descriptor { Descriptor(type: UInt32(PROX_FDTYPE_VNODE), family: nil) }
    }

    /// AF_INET and AF_INET6 sockets among `descriptors`. Unix-domain sockets (XPC, the window
    /// server) and files don't count.
    static func ipSocketCount(in descriptors: [Descriptor]) -> Int {
        descriptors.filter { $0.type == UInt32(PROX_FDTYPE_SOCKET) && ($0.family == AF_INET || $0.family == AF_INET6) }
            .count
    }

    /// Open IP sockets of this process, or nil when the kernel refused the query.
    static func ipSocketCount() -> Int? {
        descriptors(of: getpid()).map(ipSocketCount(in:))
    }

    /// Every open descriptor of `pid`, sockets with their address family.
    static func descriptors(of pid: pid_t) -> [Descriptor]? {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdSize + 16)
        let bytes = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        // `proc_pidinfo` reports a refused query as 0 bytes, not -1: "unknown", never "0 connections".
        guard bytes > 0 else { return nil }
        return fds.prefix(Int(bytes) / fdSize).map { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return Descriptor(type: fd.proc_fdtype, family: nil) }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
            return .socket(read == size ? info.psi.soi_family : nil)
        }
    }
}
