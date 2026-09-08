//
//  LocalStreamProxy.swift
//  Sona
//
//  本地流媒体代理 · Network.framework
//  - 监听 127.0.0.1:<随机端口>
//  - 接受 `GET /?u=<base64-url>` 形式的请求
//  - 转发至夸克网盘直链，补齐 Referer / Cookie / Range
//  - 流式回传，使 AVPlayer 支持秒开与任意进度 Seek
//

import Foundation
import Network

@MainActor
final class LocalStreamProxy: ObservableObject {
    static let shared = LocalStreamProxy()

    // MARK: - 公开状态

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = 0

    // MARK: - 私有

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Sona.LocalStreamProxy.Net")
    private var connections: [ObjectIdentifier: ProxyContext] = [:]

    private static let shareBaseURL = "https://pan.quark.cn"

    private struct ProxyContext {
        var client: NWConnection
        var upstreamSession: URLSession?
        var upstreamTask: URLSessionDataTask?
        var responseHeadersSent: Bool = false
        var headerBuffer: Data = Data()
    }

    private init() {
        start()
    }

    // MARK: - 启动

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback

            let listener = try NWListener(using: params, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener?.port {
                            self.port = port.rawValue
                            self.isRunning = true
                            print("[Sona Proxy] listening on http://127.0.0.1:\(port.rawValue)")
                        }
                    case .failed(let error):
                        print("[Sona Proxy] failed: \(error)")
                        self.isRunning = false
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection: connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[Sona Proxy] start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - URL 构建

    /// 生成 AVPlayer 可消费的代理 URL
    /// - Parameter referer: 上游要求的 Referer。夸克为 pan.quark.cn，阿里云盘为 www.alipan.com，
    ///   直链签名与 Referer 绑定，来源不同必须区分，否则 CDN 会拒绝。
    func makeProxyURL(for upstreamURL: URL, referer: String? = nil) -> URL? {
        guard isRunning, port > 0 else { return nil }
        let raw = upstreamURL.absoluteString
        guard let data = raw.data(using: .utf8) else { return nil }
        let encoded = data.base64EncodedString()
        let percent = encoded.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? encoded

        var query = "u=\(percent)"
        if let referer, let rData = referer.data(using: .utf8) {
            let rEncoded = rData.base64EncodedString()
            let rPercent = rEncoded.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? rEncoded
            query += "&r=\(rPercent)"
        }
        return URL(string: "http://127.0.0.1:\(port)/?\(query)")
    }

    // MARK: - 客户端连接

    private func accept(connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = ProxyContext(client: connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.receiveRequest(connection: connection, id: id)
                case .failed, .cancelled:
                    self.close(id: id)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    print("[Sona Proxy] receive error: \(error.localizedDescription)")
                    self.close(id: id)
                    return
                }

                if let data, !data.isEmpty {
                    self.connections[id]?.headerBuffer.append(data)
                }

                // 是否已接收到完整请求头
                if let range = self.connections[id]?.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = self.connections[id]!.headerBuffer.subdata(in: 0..<range.lowerBound)
                    let headerString = String(data: headerData, encoding: .utf8) ?? ""
                    self.handleRequest(headerString: headerString, id: id)
                    return
                }

                if isComplete {
                    self.close(id: id)
                    return
                }

                self.receiveRequest(connection: connection, id: id)
            }
        }
    }

    // MARK: - 请求解析与转发

    private func handleRequest(headerString: String, id: ObjectIdentifier) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respondError(id: id, status: "400 Bad Request", message: "Malformed request")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            respondError(id: id, status: "400 Bad Request", message: "Malformed request line")
            return
        }
        let method = parts[0]
        let rawPath = parts[1]

        if method != "GET" && method != "HEAD" {
            respondError(id: id, status: "405 Method Not Allowed", message: "Only GET/HEAD supported")
            return
        }

        // 收集 Range
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                rangeHeader = String(value)
                break
            }
        }

        // 解析 ?u=<base64> 与可选的 ?r=<base64 referer>
        guard let comps = URLComponents(string: "http://proxy\(rawPath)"),
              let encoded = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              let data = Data(base64Encoded: padBase64(encoded)),
              let upstreamString = String(data: data, encoding: .utf8),
              let upstreamURL = URL(string: upstreamString) else {
            respondError(id: id, status: "400 Bad Request", message: "Missing or invalid 'u' parameter")
            return
        }

        // 未显式指定来源时默认夸克，保持旧行为兼容
        let referer: String
        if let rEncoded = comps.queryItems?.first(where: { $0.name == "r" })?.value,
           let rData = Data(base64Encoded: padBase64(rEncoded)),
           let rString = String(data: rData, encoding: .utf8),
           !rString.isEmpty {
            referer = rString
        } else {
            referer = Self.shareBaseURL + "/"
        }

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        // UA 与 Referer 必须与生成直链时的 API 请求保持一致（直链签名与请求头绑定）
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(QuarkAuthService.clientUserAgent, forHTTPHeaderField: "User-Agent")
        // Cookie 仅夸克需要（阿里云盘分享匿名访问，携带无用 cookie 反而可能触发风控）
        if referer.contains("quark"), let cookie = QuarkAuthService.shared.cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let range = rangeHeader {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        // 为本次请求创建独立 ephemeral session + delegate
        let delegate = ProxyStreamDelegate(id: id, proxy: self)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 30
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": QuarkAuthService.clientUserAgent,
            "Referer": referer
        ]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        connections[id]?.upstreamSession = session
        connections[id]?.upstreamTask = task
    }

    // MARK: - 客户端响应

    fileprivate func sendHeaders(id: ObjectIdentifier, response: HTTPURLResponse) {
        guard let connection = connections[id]?.client else { return }
        var header = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        if let v = response.value(forHTTPHeaderField: "Content-Type") {
            header += "Content-Type: \(v)\r\n"
        }
        if let v = response.value(forHTTPHeaderField: "Content-Length") {
            header += "Content-Length: \(v)\r\n"
        }
        if let v = response.value(forHTTPHeaderField: "Content-Range") {
            header += "Content-Range: \(v)\r\n"
        }
        // 主动声明支持 Range
        header += "Accept-Ranges: bytes\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        if let data = header.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        connections[id]?.responseHeadersSent = true
    }

    fileprivate func sendBody(id: ObjectIdentifier, data: Data) {
        guard let connection = connections[id]?.client, !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    fileprivate func respondError(id: ObjectIdentifier, status: String, message: String) {
        guard let connection = connections[id]?.client else {
            close(id: id)
            return
        }
        let body = "\(status): \(message)"
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/plain; charset=utf-8\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = response.data(using: .utf8) ?? Data()
        payload.append(body.data(using: .utf8) ?? Data())
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
        close(id: id, retainClient: true)
    }

    fileprivate func close(id: ObjectIdentifier, retainClient: Bool = false) {
        connections[id]?.upstreamTask?.cancel()
        connections[id]?.upstreamSession?.finishTasksAndInvalidate()
        if !retainClient {
            connections[id]?.client.cancel()
        }
        connections.removeValue(forKey: id)
    }

    // MARK: - 工具

    private func padBase64(_ s: String) -> String {
        let rem = s.count % 4
        guard rem != 0 else { return s }
        return s + String(repeating: "=", count: 4 - rem)
    }
}

// MARK: - 流式代理 Delegate

private final class ProxyStreamDelegate: NSObject, URLSessionDataDelegate {
    let id: ObjectIdentifier
    weak var proxy: LocalStreamProxy?

    init(id: ObjectIdentifier, proxy: LocalStreamProxy) {
        self.id = id
        self.proxy = proxy
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let proxy = self?.proxy else {
                completionHandler(.cancel)
                return
            }
            proxy.sendHeaders(id: self!.id, response: http)
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let proxy = self?.proxy else { return }
            proxy.sendBody(id: self!.id, data: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let error {
            print("[Sona Proxy] upstream complete error: \(error.localizedDescription), status: \(status ?? -1)")
        }
        DispatchQueue.main.async { [weak self] in
            guard let proxy = self?.proxy else { return }
            proxy.close(id: self!.id)
        }
    }
}
