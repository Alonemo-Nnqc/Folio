import Foundation
import SafariServices

/// Safari may not let the extension reach http://127.0.0.1 directly; the extension then sends its
/// request here (native messaging) and this handler forwards it to Folio's connector service (WEB-01).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        nonisolated(unsafe) let context = context
        forward(message) { status, body in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: ["status": status, "body": body]]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func forward(_ message: [String: Any], completion: @escaping @Sendable (Int, String) -> Void) {
        let path = message["path"] as? String ?? "/ping"
        guard path.hasPrefix("/"), let url = URL(string: "http://127.0.0.1:23120" + path) else {
            return completion(400, #"{"error":"bad path"}"#)
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = (message["method"] as? String ?? "GET").uppercased()
        request.setValue("1", forHTTPHeaderField: "X-Folio-Connector")
        request.setValue("Safari", forHTTPHeaderField: "User-Agent")
        if let type = message["contentType"] as? String, !type.isEmpty { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let body = message["bodyBase64"] as? String, !body.isEmpty { request.httpBody = Data(base64Encoded: body) }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let response = response as? HTTPURLResponse else {
                return completion(0, #"{"error":"Folio is not running"}"#)
            }
            completion(response.statusCode, data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }.resume()
    }
}
