import Foundation

nonisolated enum EPGDownloadResult {
    case file(URL, lastModified: String?, entityTag: String?)
    case notModified
}

nonisolated extension M3UClient {
    /// Prefer the modification date: some panels advertise an ETag but ignore
    /// If-None-Match. Unsupported validators simply yield an ordinary 200.
    func downloadGuide(from urlString: String, lastModified: String? = nil, entityTag: String? = nil, maximumBytes: Int? = nil) async throws -> EPGDownloadResult {
        guard let url = URL(string: urlString) else { throw M3UError.invalidURL }
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { throw M3UError.fileNotFound }
            return try .file(gunzipIfNeeded(url, deleteOriginal: false, maximumBytes: maximumBytes), lastModified: nil, entityTag: nil)
        }
        let request = Self.guideRequest(url: url, lastModified: lastModified, entityTag: entityTag)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            try Task.checkCancellation()
            throw M3UError.networkError(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw M3UError.invalidResponse }
        if response.statusCode == 304 {
            guard lastModified != nil || entityTag != nil else { throw M3UError.serverError(304) }
            return .notModified
        }
        guard response.statusCode == 200 else { throw M3UError.serverError(response.statusCode) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xmltv")
        try FileManager.default.moveItem(at: temporary, to: destination)
        do {
            let file = try gunzipIfNeeded(destination, deleteOriginal: true, maximumBytes: maximumBytes)
            return .file(file, lastModified: response.value(forHTTPHeaderField: "Last-Modified"), entityTag: response.value(forHTTPHeaderField: "ETag"))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func guideRequest(url: URL, lastModified: String?, entityTag: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        } else if let entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }
}
