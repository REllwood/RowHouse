import Foundation
import Network
import Observation
import RowHouseCore

/// A small HTTP server for "When a webhook is received" automations. It is off by default and only
/// ever listens on 127.0.0.1, so only software on this Mac can reach it; each automation's URL also
/// carries its own secret token.
@MainActor
@Observable
final class WebhookServer {
    static let shared = WebhookServer()
    static let enabledKey = "RowHouse.webhooks.enabled"
    static let portKey = "RowHouse.webhooks.port"

    enum Status: Equatable {
        case off
        case starting(port: Int)
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .off

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var configuredPort: Int?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.rellwood.RowHouse.webhooks", qos: .userInitiated)
    @ObservationIgnored private let connections = WebhookConnections()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The port from Settings, or the default when none (or an invalid one) is stored.
    static var port: Int {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(stored) ? stored : Webhooks.defaultPort
    }

    /// Starts following the Settings switches. Call once at launch.
    func start() {
        guard defaultsObserver == nil else { return }
        applySettings()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WebhookServer.shared.applySettings() }
        }
    }

    /// Starts, stops or moves the listener to match Settings.
    func applySettings() {
        let wanted = Self.isEnabled ? Self.port : nil
        guard wanted != configuredPort else { return }
        stopListener()
        if let wanted { startListener(on: wanted) }
    }

    /// Tries again after a failure such as the port being taken.
    func restart() {
        stopListener()
        applySettings()
    }

    private func startListener(on port: Int) {
        configuredPort = port
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = .failed("\(port) isn't a valid port")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        let connections = self.connections
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connections.accept(connection, queue: queue)
        }
        listener.stateUpdateHandler = { [weak listener] state in
            Task { @MainActor in
                guard let listener, WebhookServer.shared.listener === listener else { return }
                WebhookServer.shared.listenerChanged(state, port: port)
            }
        }
        self.listener = listener
        status = .starting(port: port)
        listener.start(queue: queue)
    }

    private func listenerChanged(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready:
            status = .running(port: port)
        case .failed(let error), .waiting(let error):
            listener?.cancel()
            listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                status = .failed("Port \(port) is already in use by another app. Choose a different port.")
            } else {
                status = .failed(error.localizedDescription)
            }
        default:
            break
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        configuredPort = nil
        status = .off
        let connections = self.connections
        queue.async { connections.cancelAll() }
    }
}

/// Open connections, touched only on the server's queue.
private final class WebhookConnections: @unchecked Sendable {
    static let maxOpen = 16
    private var open: [ObjectIdentifier: WebhookConnection] = [:]

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let exchange = WebhookConnection(connection: connection, queue: queue) { [weak self] finished in
            self?.open[ObjectIdentifier(finished)] = nil
        }
        if open.count >= Self.maxOpen {
            exchange.start(rejectingWith: .error(503, "Too many open connections; try again shortly"))
            return
        }
        open[ObjectIdentifier(exchange)] = exchange
        exchange.start()
    }

    func cancelAll() {
        for exchange in open.values { exchange.cancel() }
        open.removeAll()
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }
}

/// One HTTP exchange: read a single request, answer it, close the connection.
private final class WebhookConnection: @unchecked Sendable {
    static let timeout: TimeInterval = 30

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: (WebhookConnection) -> Void
    private var buffer = Data()
    private var expectedTotal: Int?
    private var sentContinue = false
    private var dispatched = false
    private var finished = false

    init(connection: NWConnection, queue: DispatchQueue, onClose: @escaping (WebhookConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, !self.dispatched else { return }
            self.respond(.error(408, "Timed out waiting for the request"))
        }
        receive()
    }

    func start(rejectingWith response: WebhookResponse) {
        connection.start(queue: queue)
        respond(response)
    }

    func cancel() {
        finished = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            if error != nil {
                cancel()
                return
            }
            process(streamEnded: isComplete)
        }
    }

    private func process(streamEnded: Bool) {
        // Once the headers say how long the request is, don't re-parse until all of it has arrived.
        if let expectedTotal, buffer.count < expectedTotal {
            if streamEnded { respond(.error(400, "The request ended before its body did")) } else { receive() }
            return
        }
        do {
            switch try WebhookRequest.parse(buffer) {
            case .complete(let request):
                dispatch(request)
            case .incomplete(let total, let expectsContinue):
                expectedTotal = total
                if streamEnded {
                    respond(.error(400, "The request ended early"))
                    return
                }
                if expectsContinue && !sentContinue {
                    sentContinue = true
                    connection.send(content: WebhookResponse.continueBytes, completion: .idempotent)
                }
                receive()
            }
        } catch let error as WebhookRequest.ParseError {
            respond(.error(error.status, error.message))
        } catch {
            respond(.error(400, "Malformed request"))
        }
    }

    private func dispatch(_ request: WebhookRequest) {
        dispatched = true
        Task { @MainActor in
            let response = await AutomationEngine.respond(to: request, engines: Array(AppModel.shared.engines.values))
            self.queue.async { self.respond(response) }
        }
    }

    private func respond(_ response: WebhookResponse) {
        guard !finished else { return }
        finished = true
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    private func close() {
        finished = true
        connection.stateUpdateHandler = nil
        onClose(self)
    }
}
