import Foundation
import Network

/// Serves the signed, read-only editor resources on this device. A stable HTTP
/// origin allows WebKit to keep its notebook database and run local PDF workers.
final class BundledEditor {
    private let queue = DispatchQueue(label: "app.gridnote.bundled-editor")
    private let root: URL
    private var listener: NWListener?
    private let portKey = "notebookOriginPort"
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(root: URL) { self.root = root }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            do {
                let previous = UserDefaults.standard.integer(forKey: self.portKey)
                let port = UInt16(exactly: previous).flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                var reported = false
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, !reported else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        reported = true
                        UserDefaults.standard.set(Int(port.rawValue), forKey: self.portKey)
                        let origin = URL(string: "http://127.0.0.1:\(port.rawValue)/app/")!
                        DispatchQueue.main.async { completion(.success(origin)) }
                    case .failed(let error):
                        reported = true
                        listener.cancel()
                        DispatchQueue.main.async { completion(.failure(error)) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    let key = ObjectIdentifier(connection)
                    self.connections[key] = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .cancelled = state { self?.connections.removeValue(forKey: key) }
                    }
                    connection.start(queue: self.queue)
                    self.receive(connection, prefix: Data())
                }
                listener.start(queue: self.queue)
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = prefix + data
            guard request.count <= 16384 else { connection.cancel(); return }
            if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: request[..<end.lowerBound], as: UTF8.self)
                self.serve(headers, connection)
            } else if ended { connection.cancel() }
            else { self.receive(connection, prefix: request) }
        }
    }

    private func serve(_ headers: String, _ connection: NWConnection) {
        let lines = headers.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        let host = "127.0.0.1:\(listener?.port?.rawValue ?? 0)"
        let suppliedHost = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
        guard suppliedHost?.dropFirst(5).trimmingCharacters(in: .whitespaces) == host,
              fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD",
              let path = URLComponents(string: String(fields[1]))?.path,
              path.hasPrefix("/app/") else {
            send(connection, status: "404 Not Found"); return
        }
        let components = path.dropFirst(5).split(separator: "/")
        guard components.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("\\") }) else {
            send(connection, status: "404 Not Found"); return
        }
        let file = root.appendingPathComponent(components.isEmpty ? "index.html" : components.joined(separator: "/"))
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            send(connection, status: "404 Not Found"); return
        }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript", "mjs": "text/javascript",
                     "css": "text/css", "png": "image/png", "svg": "image/svg+xml", "json": "application/json",
                     "webmanifest": "application/manifest+json", "wasm": "application/wasm", "gz": "application/gzip",
                     "ttf": "font/ttf", "woff2": "font/woff2"]
        send(connection, status: "200 OK", type: types[file.pathExtension] ?? "application/octet-stream",
             body: data, head: fields[0] == "HEAD")
    }

    private func send(_ connection: NWConnection, status: String, type: String = "text/plain",
                      body: Data = Data(), head: Bool = false) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
