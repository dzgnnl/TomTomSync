import Foundation

/// Looks up the latest GitHub release. Installing stays with Homebrew
/// (`brew upgrade`); in-app updates would need a Developer ID (see ROADMAP).
public enum UpdateCheck {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: URL
    }

    static let latestURL = URL(string: "https://api.github.com/repos/dzgnnl/TomTomSync/releases/latest")!

    public static func latest() async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WatchError.badResponse("update check failed (HTTP \(status))") }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        struct Body: Decodable { var tag_name: String; var html_url: URL }
        let b = try JSONDecoder().decode(Body.self, from: data)
        return Release(version: b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name, url: b.html_url)
    }

    /// Compares dotted version numbers ("0.10.0" > "0.9.1"). A leading "v" and
    /// anything after "-" (e.g. "-3-gabc123" from `git describe`) are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = (s.hasPrefix("v") ? s.dropFirst() : Substring(s)).split(separator: "-").first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
