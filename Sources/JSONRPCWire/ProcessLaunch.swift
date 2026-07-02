/// How to launch a child process that speaks JSON-RPC over stdio.
///
/// A generic, transport-agnostic launch descriptor shared by every stdio
/// consumer (LSP, ACP, MCP). Not tied to any one process API — `Foundation.Process`
/// and `swift-subprocess` both consume it. It lives in `JSONRPCWire` because that
/// is the shared, dependency-free module both stdio transports (`JSONRPCStdio` and
/// `JSONRPCSubprocess`) already import — it is a launch *description*, not I/O.
public struct ProcessLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var workingDirectory: String?
    /// When true the child's stderr (its own logs) passes through to this process's
    /// stderr; when false it is discarded. Either way it stays off the JSON-RPC
    /// stdout stream.
    public var inheritStderr: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        inheritStderr: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.inheritStderr = inheritStderr
    }
}
