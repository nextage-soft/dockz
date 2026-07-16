import AppKit
import Foundation

/// Fetches Docker Hub logos for image references, with memory + disk caching
/// (~/.dockz/logo-cache). Official images come from the repos_logo endpoint;
/// verified publishers fall back to the search API's logo_url. Anything else
/// (private registries, digests, misses) resolves to nil → gradient avatar.
final class ImageLogoLoader {
    static let shared = ImageLogoLoader()

    private let memoryCache = NSCache<NSString, NSImage>()
    private var misses = Set<String>()
    private var inflight = [String: [(NSImage?) -> Void]]()
    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.logo-loader")
    private let diskDirectory: URL

    private init() {
        diskDirectory = DockzPaths().baseDirectory.appendingPathComponent("logo-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Completion is always delivered on the main queue.
    func load(imageRef: String, completion: @escaping (NSImage?) -> Void) {
        guard let repo = Self.normalizedRepo(from: imageRef) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let key = repo as NSString
        if let cached = memoryCache.object(forKey: key) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        queue.async {
            if self.misses.contains(repo) {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if let disk = self.loadFromDisk(repo) {
                self.memoryCache.setObject(disk, forKey: key)
                DispatchQueue.main.async { completion(disk) }
                return
            }
            if self.inflight[repo] != nil {
                self.inflight[repo]?.append(completion)
                return
            }
            self.inflight[repo] = [completion]
            self.fetchLogo(repo: repo) { image in
                self.queue.async {
                    let waiters = self.inflight.removeValue(forKey: repo) ?? []
                    if let image {
                        self.memoryCache.setObject(image, forKey: key)
                        self.saveToDisk(repo, image: image)
                    } else {
                        self.misses.insert(repo)
                    }
                    DispatchQueue.main.async { waiters.forEach { $0(image) } }
                }
            }
        }
    }

    // MARK: - Reference parsing

    /// "postgres:17" → "library/postgres"; "grafana/grafana:latest" →
    /// "grafana/grafana"; ghcr.io/…, digests and raw ids → nil.
    static func normalizedRepo(from imageRef: String) -> String? {
        var ref = imageRef
        if ref.hasPrefix("sha256:") || ref.isEmpty { return nil }
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        // Strip the tag: last ':' that appears after the last '/'.
        if let colon = ref.lastIndex(of: ":"),
           ref[colon...].lastIndex(of: "/") == nil {
            ref = String(ref[..<colon])
        }
        let components = ref.split(separator: "/").map(String.init)
        switch components.count {
        case 1:
            return "library/\(components[0])"
        case 2 where !components[0].contains(".") && !components[0].contains(":"):
            return ref
        default:
            return nil // private registry or nested path — no Hub logo
        }
    }

    // MARK: - Network

    private func fetchLogo(repo: String, completion: @escaping (NSImage?) -> Void) {
        let escaped = repo.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://hub.docker.com/api/media/repos_logo/v1/\(escaped)") else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = NSImage(data: data), image.isValid {
                completion(image)
                return
            }
            self.fetchFromSearch(repo: repo, completion: completion)
        }.resume()
    }

    private func fetchFromSearch(repo: String, completion: @escaping (NSImage?) -> Void) {
        let namespace = repo.split(separator: "/").first.map(String.init) ?? repo
        guard namespace != "library",
              let query = repo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://hub.docker.com/api/search/v3/catalog/search?query=\(query)&from=0&size=5") else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            let match = results.first { ($0["id"] as? String) == repo }
                ?? results.first { ($0["id"] as? String) == namespace }
            guard let logoURLText = ((match?["logo_url"] as? [String: Any])?["small"] as? String),
                  !logoURLText.hasSuffix(".svg"),
                  let logoURL = URL(string: logoURLText) else {
                completion(nil)
                return
            }
            URLSession.shared.dataTask(with: logoURL) { logoData, _, _ in
                guard let logoData, let image = NSImage(data: logoData), image.isValid else {
                    completion(nil)
                    return
                }
                completion(image)
            }.resume()
        }.resume()
    }

    // MARK: - Disk cache

    private func diskURL(_ repo: String) -> URL {
        diskDirectory.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    private func loadFromDisk(_ repo: String) -> NSImage? {
        guard let data = try? Data(contentsOf: diskURL(repo)) else { return nil }
        return NSImage(data: data)
    }

    private func saveToDisk(_ repo: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: diskURL(repo))
    }
}
