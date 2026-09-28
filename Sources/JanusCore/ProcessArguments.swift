import Darwin
import Foundation

/// The command line another process was started with.
///
/// Two copies of Claude started from the same app are told apart only by the
/// `--user-data-dir` each was given, and nothing in AppKit exposes a running
/// app's arguments. The kernel does, through `KERN_PROCARGS2`, for any process
/// owned by the same user.
public enum ProcessArguments {

    /// Arguments of a running process, `argv[0]` included, or empty when the
    /// process has gone or belongs to someone else.
    public static func of(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parse(Array(buffer.prefix(size)))
    }

    /// Reads the layout `KERN_PROCARGS2` answers with: a 32-bit `argc`, the
    /// executable path, padding NULs, then `argc` NUL-terminated arguments and,
    /// after them, the environment, which is deliberately not read.
    static func parse(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
