import Foundation
import Network

/// Finds Sonos speakers on the local network (they announce themselves as "_sonos._tcp").
/// This needs the macOS "Local Network" permission.
public final class BonjourDiscovery: @unchecked Sendable {
    public init() {}

    public func discover(maxWait: TimeInterval = 4) async -> DiscoveryResult {
        await withCheckedContinuation { continuation in
            let session = Session(maxWait: maxWait) { continuation.resume(returning: $0) }
            session.start()
        }
    }

    /// One search. Everything runs on one serial queue, so no locks are needed.
    private final class Session: @unchecked Sendable {
        private let queue = DispatchQueue(label: "mac-sonos-control.discovery")
        private let maxWait: TimeInterval
        private let done: (DiscoveryResult) -> Void
        private var browser: NWBrowser?
        private var connections: [NWConnection] = []
        private var hosts: [String] = []
        private var denied = false
        private var finished = false
        private var graceScheduled = false

        init(maxWait: TimeInterval, done: @escaping (DiscoveryResult) -> Void) {
            self.maxWait = maxWait
            self.done = done
        }

        func start() {
            let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == -65570 { // "policy denied": no Local Network access
                        self.denied = true
                        self.finish()
                    }
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                results.forEach { self?.resolve($0.endpoint) }
            }
            browser.start(queue: queue)
            // Strong reference on purpose: this keeps the search alive until it finishes.
            queue.asyncAfter(deadline: .now() + maxWait) { self.finish() }
        }

        private func resolve(_ endpoint: NWEndpoint) {
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let connection = NWConnection(to: endpoint, using: parameters)
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let address) = host {
                        let text = "\(address)".components(separatedBy: "%")[0]
                        if !self.hosts.contains(text) { self.hosts.append(text) }
                        self.finishSoon()
                    }
                    connection.cancel()
                case .failed:
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
        }

        /// Once one speaker is found, wait a moment for others, then stop; the speakers tell us about each other anyway.
        private func finishSoon() {
            guard !graceScheduled else { return }
            graceScheduled = true
            queue.asyncAfter(deadline: .now() + 0.4) { self.finish() }
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            browser?.cancel()
            connections.forEach { $0.cancel() }
            done(DiscoveryResult(hosts: hosts, localNetworkDenied: denied && hosts.isEmpty))
        }
    }
}
