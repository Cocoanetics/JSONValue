import Foundation

/// Runs the blocking read → framing → dispatch loop shared by every transport that
/// drains a file descriptor on a dedicated thread (`Foundation.Process` stdout, a
/// connected TCP socket, the current process's own stdin).
///
/// The loop keeps its own value copy of `framing` as the decode buffer (see
/// ``MessageFraming``), reads until EOF, and hands each complete message body to
/// `onBody`. This module stays I/O-free: `readChunk` performs the actual blocking
/// read — an **empty `Data` means EOF** (map read errors to empty as well). All
/// three closures run on the spawned reader thread; `onEOF` runs exactly once,
/// after the last body, before the thread exits.
///
/// - Parameters:
///   - name: The reader thread's name (e.g. `"jsonrpc.tcp.reader"`).
///   - framing: The wire framing whose value copy buffers partial frames.
///   - readChunk: Blocking read returning the next chunk; empty signals EOF.
///   - onBody: Receives each complete, unframed message body.
///   - onEOF: Runs once after `readChunk` returns empty (typically finishing the
///     inbound stream).
package func startFramedReaderThread(
    name: String,
    framing: some MessageFraming,
    readChunk: @escaping @Sendable () -> Data,
    onBody: @escaping @Sendable (Data) -> Void,
    onEOF: @escaping @Sendable () -> Void
) {
    let thread = Thread {
        var decoder = framing
        while true {
            let chunk = readChunk()
            if chunk.isEmpty { break }
            for body in decoder.push(chunk) {
                onBody(body)
            }
        }
        onEOF()
    }
    thread.name = name
    thread.stackSize = 4 << 20
    thread.start()
}
