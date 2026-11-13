import Foundation

struct PublicRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: AppVersion? { AppVersion.releaseTag(tag_name) }
    static func trustedURL(_ url: URL, download: Bool = false) -> Bool {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let parts = url.pathComponents
        return parts.count >= (download ? 7 : 6) && Array(parts.prefix(5)) == ["/", "iyk2h", "nearclip", "releases", download ? "download" : "tag"] && !parts.contains("..")
    }
    var downloadURL: URL? {
        assets.first { $0.name.hasPrefix("NearClip-") && $0.name.hasSuffix("-macOS.dmg") && Self.trustedURL($0.browser_download_url, download: true) }?.browser_download_url
    }
    static func newest(_ data: Data, includeBeta: Bool) throws -> Self? {
        guard data.count <= 2 * 1024 * 1024 else { throw ClipError.invalid("업데이트 응답이 너무 커요.") }
        let releases = try JSONDecoder().decode([Self].self, from: data)
        return releases.filter { !$0.draft && (includeBeta || !$0.prerelease) && $0.version != nil && trustedURL($0.html_url) && $0.downloadURL != nil }
            .max { $0.version! < $1.version! }
    }
}

final class UpdateChecker: NSObject, URLSessionTaskDelegate {
    static let releasesURL = URL(string: "https://github.com/iyk2h/nearclip/releases")!
    private(set) var checking = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    // No cookies, credentials, pairing metadata, or clipboard data are sent.
    func check(includeBeta: Bool = true, completion: @escaping (Result<PublicRelease?, Error>) -> Void) {
        guard !checking else { return }; checking = true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/iyk2h/nearclip/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NearClip-Update-Check", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<PublicRelease?, Error>
            if let error { result = .failure(error) }
            else if let response = response as? HTTPURLResponse, response.statusCode == 200, let data {
                result = Result { try PublicRelease.newest(data, includeBeta: includeBeta) }
            } else { result = .failure(ClipError.invalid("업데이트를 확인하지 못했어요. 잠시 후 다시 시도해 주세요.")) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false; self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil
                completion(result)
            }
        }
        task?.resume()
    }
    func cancel() { task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil; checking = false }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // A moved repository must be reviewed in an app update.
    }
}
