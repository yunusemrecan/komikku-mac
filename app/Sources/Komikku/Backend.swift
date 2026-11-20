// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs the Python backend (`python -m komikku_mac`) and talks JSON-RPC to it
// over stdin/stdout, one JSON object per line.

import Foundation

struct BackendError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

final class Backend: @unchecked Sendable {
    typealias RequestHandler = @MainActor (_ method: String, _ params: [String: Any]) async throws -> Any?
    typealias NotificationHandler = @MainActor (_ method: String, _ params: [String: Any]) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private let lock = NSLock()
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var isReady = false

    /// Called when the backend asks the frontend for something (webview work).
    var requestHandler: RequestHandler?
    /// Called for backend notifications (progress, etc.).
    var notificationHandler: NotificationHandler?
    /// Called when the backend process exits unexpectedly.
    var terminationHandler: (@MainActor (Int32) -> Void)?

    // MARK: - Locating the bundled Python and sources

    struct Layout {
        let python: URL
        let backendDir: URL
        let upstreamDir: URL
    }

    static func locate() throws -> Layout {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        // Development override: run against a checkout with any Python
        if let backendPath = env["KOMIKKU_BACKEND_DIR"] {
            let backendDir = URL(fileURLWithPath: backendPath)
            let python = URL(fileURLWithPath: env["KOMIKKU_PYTHON"] ?? "/usr/bin/python3")
            let upstream = URL(fileURLWithPath: env["KOMIKKU_UPSTREAM"] ?? backendDir.deletingLastPathComponent().appendingPathComponent("upstream").path)
            return Layout(python: python, backendDir: backendDir, upstreamDir: upstream)
        }

        guard let resources = Bundle.main.resourceURL else {
            throw BackendError(code: "layout", message: "Uygulama kaynak klasörü bulunamadı")
        }
        let python = resources.appendingPathComponent("python/bin/python3")
        let backendDir = resources.appendingPathComponent("backend")
        let upstreamDir = resources.appendingPathComponent("upstream")
        guard fm.isExecutableFile(atPath: python.path) else {
            throw BackendError(code: "layout", message: "Gömülü Python bulunamadı: \(python.path)")
        }
        return Layout(python: python, backendDir: backendDir, upstreamDir: upstreamDir)
    }

    // MARK: - Lifecycle

    func start() throws {
        let layout = try Backend.locate()

        let process = Process()
        process.executableURL = layout.python
        process.arguments = ["-u", "-m", "komikku_mac"]
        process.currentDirectoryURL = layout.backendDir

        var env = ProcessInfo.processInfo.environment
        env["KOMIKKU_UPSTREAM"] = layout.upstreamDir.path
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONPATH"] = layout.backendDir.path
        env.removeValue(forKey: "PYTHONHOME")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Backend.log(data)
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.failAll(BackendError(code: "exited", message: "Arka uç kapandı (kod \(proc.terminationStatus))"))
            let status = proc.terminationStatus
            Task { @MainActor in self.terminationHandler?(status) }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    /// Closes stdin so the backend can finish (e.g. clear cache on exit), then terminates it.
    func stop() {
        try? stdinHandle?.close()
        guard let process else { return }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
    }

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isReady {
                lock.unlock()
                continuation.resume()
            } else {
                readyContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: - Logging

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Komikku", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backend.log")
    }()

    private static let logLock = NSLock()

    private static func log(_ data: Data) {
        logLock.lock()
        defer { logLock.unlock() }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: - Sending

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        stdinHandle?.write(data)
        stdinHandle?.write(Data([0x0A]))
    }

    /// Raw call returning the decoded JSON value (`Any?`).
    func callRaw(_ method: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = continuation
            lock.unlock()
            send(["id": id, "method": method, "params": params])
        }
    }

    /// Typed call: the JSON result is decoded into `T` (snake_case keys).
    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let raw = try await callRaw(method, params)
        let data = try JSONSerialization.data(withJSONObject: raw ?? NSNull(), options: [.fragmentsAllowed])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Receiving

    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                // Backend -> frontend request
                let idBox = IDBox(value: id)
                let paramsBox = ParamsBox(value: params)
                Task { @MainActor in
                    await self.answer(id: idBox, method: method, params: paramsBox.value)
                }
            } else if method == "backend.ready" {
                lock.lock()
                isReady = true
                let waiting = readyContinuations
                readyContinuations.removeAll()
                lock.unlock()
                waiting.forEach { $0.resume() }
            } else {
                let paramsBox = ParamsBox(value: params)
                Task { @MainActor in
                    self.notificationHandler?(method, paramsBox.value)
                }
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }

        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: BackendError(
                code: error["code"] as? String ?? "error",
                message: error["message"] as? String ?? "Bilinmeyen hata"
            ))
        } else {
            continuation.resume(returning: message["result"])
        }
    }

    @MainActor
    private func answer(id: IDBox, method: String, params: [String: Any]) async {
        do {
            guard let handler = requestHandler else {
                throw BackendError(code: "not_supported", message: "No handler for \(method)")
            }
            let result = try await handler(method, params)
            send(["id": id.value, "result": result ?? NSNull()])
        } catch {
            send(["id": id.value, "error": ["code": "frontend_error", "message": error.localizedDescription]])
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        let ready = readyContinuations
        readyContinuations.removeAll()
        lock.unlock()
        waiting.values.forEach { $0.resume(throwing: error) }
        ready.forEach { $0.resume(throwing: error) }
    }
}

// Boxes to move non-Sendable JSON values across actor hops (values are immutable).
private struct IDBox: @unchecked Sendable { let value: Any }
private struct ParamsBox: @unchecked Sendable { let value: [String: Any] }
