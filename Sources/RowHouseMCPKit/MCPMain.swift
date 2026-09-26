import Foundation

/// Runs the server over standard input and output until the client closes stdin or the process is
/// asked to stop. Requests are handled one at a time on the main actor; stdin is read on its own thread.
public enum MCPMain {
    static let maintenanceInterval: Duration = .seconds(300)

    @MainActor
    public static func run(configuration: MCPServer.Configuration = MCPServer.Configuration()) -> Never {
        // A client that goes away mid-reply must not kill the process before it saves its snapshots.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer(configuration: configuration)

        let lines = AsyncStream<String> { continuation in
            let reader = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            reader.name = "rowhouse-mcp stdin"
            reader.start()
        }

        Task { @MainActor in
            for await line in lines {
                guard let reply = await server.handle(line) else { continue }
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8))
                } catch {
                    Log.info("the client closed the connection")
                    break
                }
            }
            stop(server)
        }

        Task { @MainActor in
            while true {
                try? await Task.sleep(for: maintenanceInterval)
                server.performMaintenance()
            }
        }

        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { server.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        withExtendedLifetime(signalSources) {
            dispatchMain()
        }
    }

    @MainActor
    private static func stop(_ server: MCPServer) -> Never {
        server.shutdown()
        exit(0)
    }
}
