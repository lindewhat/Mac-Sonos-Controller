import AppKit

/// Fetches cover art from the speaker itself (plain HTTP on the local network) and remembers the last few,
/// so opening the menu never waits on a download. Nothing leaves the local network: the library only ever
/// hands us addresses on the speaker.
@MainActor
final class ArtLoader {
    /// Called when a cover has arrived, so the menu can redraw with it.
    var onLoaded: ((URL) -> Void)?

    private var cache: [URL: NSImage] = [:]
    private var order: [URL] = []
    private var loading = Set<URL>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func cached(_ url: URL) -> NSImage? { cache[url] }

    /// Starts a download unless the picture is already here or on its way. Failure just means no cover.
    func fetch(_ url: URL) {
        guard cache[url] == nil, loading.insert(url).inserted else { return }
        Task {
            let image = await download(url)
            loading.remove(url)
            guard let image else { return }
            cache[url] = image
            order.append(url)
            if order.count > 6 { cache[order.removeFirst()] = nil }
            onLoaded?(url)
        }
    }

    private func download(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { return nil }
        return NSImage(data: data)
    }
}
