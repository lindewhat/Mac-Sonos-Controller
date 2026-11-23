import Foundation

/// The Sonos services we use. Sonos speakers answer these on port 1400.
public enum SonosService: Sendable {
    case avTransport, zoneGroupTopology, renderingControl, groupRenderingControl, contentDirectory

    var urn: String {
        switch self {
        case .avTransport: return "urn:schemas-upnp-org:service:AVTransport:1"
        case .zoneGroupTopology: return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: return "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .contentDirectory: return "urn:schemas-upnp-org:service:ContentDirectory:1"
        }
    }

    var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .contentDirectory: return "/MediaServer/ContentDirectory/Control"
        }
    }
}

/// One command to a speaker, e.g. AVTransport "Play".
public struct SOAPCall: Equatable, Sendable {
    public let service: SonosService
    public let action: String
    public let arguments: [(name: String, value: String)]

    public init(service: SonosService, action: String, arguments: [(name: String, value: String)] = []) {
        self.service = service
        self.action = action
        self.arguments = arguments
    }

    public static func == (a: SOAPCall, b: SOAPCall) -> Bool {
        a.service.urn == b.service.urn && a.action == b.action
            && a.arguments.map { $0.name + "=" + $0.value } == b.arguments.map { $0.name + "=" + $0.value }
    }

    public var soapActionHeader: String { "\"\(service.urn)#\(action)\"" }

    public var body: String {
        let args = arguments.map { "<\($0.name)>\(Self.escape($0.value))</\($0.name)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.urn)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Sends a command to one speaker and returns the answer as name -> text.
public protocol SonosTransport: Sendable {
    func send(_ call: SOAPCall, to host: String) async throws -> [String: String]
}

/// The real thing: plain HTTP to the speaker on the local network.
public struct HTTPSonosTransport: SonosTransport {
    private let session: URLSession
    private let log: Log?
    private let labels = SpeakerLabels()

    /// `log` is where failures are recorded (the app passes its own; tests pass none, so they never write a real log).
    public init(session: URLSession? = nil, timeout: TimeInterval = 3, log: Log? = nil) {
        self.log = log
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ call: SOAPCall, to host: String) async throws -> [String: String] {
        guard let url = URL(string: "http://\(host):1400\(call.service.controlPath)") else {
            log?.error("sonos", "\(call.action) failed: bad speaker address")
            throw SonosError.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(call.soapActionHeader, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(call.body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log?.error("sonos", "\(labels.label(for: host)) \(call.action) failed: no answer (\(Self.describe(error)))")
            throw SonosError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            log?.error("sonos", "\(labels.label(for: host)) \(call.action) failed: not an HTTP answer")
            throw SonosError.badResponse
        }
        let values = SimpleXML.leafValues(in: data)
        if http.statusCode == 200 {
            log?.trace("sonos", "\(labels.label(for: host)) \(call.action) ok")
            return values
        }
        // Sonos answers refusals with HTTP 500 and a UPnP error code.
        if http.statusCode == 500 {
            log?.warn("sonos", "\(labels.label(for: host)) \(call.action) refused by the speaker (HTTP 500, UPnP error \(values["errorCode"] ?? "unknown"))")
            throw SonosError.notAllowed
        }
        log?.error("sonos", "\(labels.label(for: host)) \(call.action) failed: unexpected HTTP \(http.statusCode)")
        throw SonosError.badResponse
    }

    /// The reason a request got no answer, in words (the numbers are Apple's URL error codes).
    static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "timed out"
        case NSURLErrorCannotConnectToHost: return "connection refused"
        case NSURLErrorNetworkConnectionLost: return "connection lost"
        case NSURLErrorNotConnectedToInternet: return "this Mac is offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "address not found"
        default: return "error \(code)"
        }
    }
}

/// Names speakers "speaker 1", "speaker 2"... in the order they are first seen since the app started, so a log
/// can tell speakers apart without containing any address. The numbers mean nothing outside one run of the app.
final class SpeakerLabels: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Int] = [:]

    func label(for host: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let number = seen[host] { return "speaker \(number)" }
        seen[host] = seen.count + 1
        return "speaker \(seen.count)"
    }
}
