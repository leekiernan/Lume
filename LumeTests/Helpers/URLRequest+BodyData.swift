//
//  URLRequest+BodyData.swift
//  LumeTests
//
//  The body a stub `URLProtocol` actually receives. URLSession moves a
//  request's `httpBody` into `httpBodyStream` before a protocol sees it, so a
//  stub reading `request.httpBody` gets nil for every POST — which silently
//  turned "the client sent the right payload" assertions into failures.
//

import Foundation

extension URLRequest {
    /// `httpBody` when present, otherwise the fully drained `httpBodyStream`.
    nonisolated var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0 ..< read])
        }
        return data
    }
}
