import Foundation

/// Keep the script payload intact, including base64 '+' characters, when StikDebug
/// reads the query using either URLComponents or a form-style query decoder.
enum StikJITRequest {
    static func url(bundleID: String, scriptBase64: String) -> URL? {
        var components = URLComponents()
        components.scheme = "stikjit"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "script-data", value: scriptBase64)
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
