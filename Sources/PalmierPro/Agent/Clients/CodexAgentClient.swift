import Foundation
import MCP

struct CodexAgentClient: AgentClient {
    let settings: AgentRunSettings

    func stream(
        system: String,
        tools _: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            try await CodexAppServer.shared.runTurn(
                settings: settings,
                system: system,
                messages: messages,
                context: context,
                continuation: continuation
            )
        }
    }
}

enum CodexAppServerError: LocalizedError, Sendable {
    case notInstalled
    case launchFailed(String)
    case connectionClosed
    case invalidResponse(String)
    case requestFailed(String)
    case turnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Install or update Codex to use it for in-app chat."
        case .launchFailed(let message):
            "Codex could not start: \(message)"
        case .connectionClosed:
            "The Codex connection closed. Send the message again."
        case .invalidResponse(let message):
            "Codex returned an invalid response: \(message)"
        case .requestFailed(let message), .turnFailed(let message):
            message
        }
    }
}

actor CodexAppServer {
    static let shared = CodexAppServer()

    private struct ActiveTurn {
        let conversationID: UUID
        let threadID: String
        var turnID: String?
        var receivedText = false
        let stream: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
        let completion: CheckedContinuation<Void, any Error>
    }

    private var process: Process?
    private var input: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var startupTask: Task<Void, any Error>?
    private var isInitialized = false
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<Value, any Error>] = [:]
    private var conversationThreads: [UUID: String] = [:]
    private var activeTurns: [String: ActiveTurn] = [:]

    nonisolated static func isInstalled() async -> Bool {
        await Task.detached(priority: .utility) {
            executableURL() != nil
        }.value
    }

    func runTurn(
        settings: AgentRunSettings,
        system: String,
        messages: [AgentRequestMessage],
        context: AgentRequestContext,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        try await ensureStarted()
        try Task.checkCancellation()

        let existingThreadID = conversationThreads[context.conversationID]
        let threadID: String
        if let existingThreadID {
            threadID = existingThreadID
        } else {
            threadID = try await startThread(
                settings: settings,
                system: system,
                conversationID: context.conversationID
            )
        }
        let input = try turnInput(messages: messages, includeHistory: existingThreadID == nil)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                activeTurns[threadID] = ActiveTurn(
                    conversationID: context.conversationID,
                    threadID: threadID,
                    stream: continuation,
                    completion: completion
                )
                Task {
                    await self.beginTurn(
                        threadID: threadID,
                        settings: settings,
                        input: input,
                        inputMessageID: context.inputMessageID
                    )
                }
            }
        } onCancel: {
            Task {
                await CodexAppServer.shared.cancelTurn(
                    conversationID: context.conversationID,
                    threadID: threadID
                )
            }
        }
    }

    private func ensureStarted() async throws {
        if isInitialized { return }
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { try await startAndInitialize() }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            connectionEnded()
            throw error
        }
    }

    private func startAndInitialize() async throws {
        guard let executable = await Self.installedExecutableURL() else {
            throw CodexAppServerError.notInstalled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        var arguments = [
            "app-server", "--stdio",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "remote_plugin",
            "--disable", "skill_search",
            "--disable", "tool_suggest",
        ]
        arguments.append(contentsOf: await Self.disabledMCPArguments())
        arguments.append(contentsOf: [
            "-c", "mcp_servers.creatorstudio-editor.url=\"http://127.0.0.1:\(MCPService.port)/mcp\"",
            "-c", "mcp_servers.creatorstudio-editor.enabled=true",
        ])
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        self.process = process
        input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        outputTask = Task { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    await self?.receive(line: line)
                }
            } catch {
                await self?.connectionEnded()
                return
            }
            await self?.connectionEnded()
        }

        _ = try await request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": "creatorstudio-editor",
                    "title": "CreatorStudio Editor",
                    "version": "1.0.0",
                ]),
                "capabilities": .object([
                    "experimentalApi": true,
                    "requestAttestation": false,
                ]),
            ])
        )
        try notify(method: "initialized")
        isInitialized = true
    }

    private func startThread(
        settings: AgentRunSettings,
        system: String,
        conversationID: UUID
    ) async throws -> String {
        let result = try await request(
            method: "thread/start",
            params: .object([
                "model": .string(settings.model.rawValue),
                "cwd": .string(FileManager.default.temporaryDirectory.path),
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
                "serviceName": "CreatorStudio Editor",
                "baseInstructions": .string(system),
                "developerInstructions": .string(
                    "Use only the creatorstudio-editor MCP server for project inspection and edits. "
                    + "Do not run shell commands, inspect files, or use unrelated MCP servers. "
                    + "Apply requested editor changes with MCP tools, then answer concisely."
                ),
            ])
        )
        guard let threadID = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerError.invalidResponse("thread/start omitted the thread ID")
        }
        conversationThreads[conversationID] = threadID
        return threadID
    }

    private func beginTurn(
        threadID: String,
        settings: AgentRunSettings,
        input: [Value],
        inputMessageID: UUID
    ) async {
        do {
            let result = try await request(
                method: "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "clientUserMessageId": .string(inputMessageID.uuidString.lowercased()),
                    "input": .array(input),
                    "model": .string(settings.model.rawValue),
                    "effort": .string(settings.reasoningEffort.rawValue),
                ])
            )
            guard let turnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
                finishTurn(
                    threadID: threadID,
                    result: .failure(.invalidResponse("turn/start omitted the turn ID"))
                )
                return
            }
            guard var active = activeTurns[threadID] else {
                Task { await self.interrupt(threadID: threadID, turnID: turnID) }
                return
            }
            active.turnID = turnID
            activeTurns[threadID] = active
        } catch let error as CodexAppServerError {
            finishTurn(threadID: threadID, result: .failure(error))
        } catch {
            finishTurn(threadID: threadID, result: .failure(.requestFailed(error.localizedDescription)))
        }
    }

    private func cancelTurn(conversationID: UUID, threadID: String) {
        guard let active = activeTurns[threadID], active.conversationID == conversationID else { return }
        let turnID = active.turnID
        activeTurns.removeValue(forKey: threadID)?.completion.resume(throwing: CancellationError())
        guard let turnID else { return }
        Task { await self.interrupt(threadID: threadID, turnID: turnID) }
    }

    private func interrupt(threadID: String, turnID: String) async {
        _ = try? await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    private func turnInput(messages: [AgentRequestMessage], includeHistory: Bool) throws -> [Value] {
        guard let currentIndex = messages.lastIndex(where: { $0.role == .user }) else {
            throw CodexAppServerError.invalidResponse("the chat has no user message")
        }

        var inputs: [Value] = []
        if includeHistory, currentIndex > messages.startIndex {
            let history = conversationHistory(Array(messages[..<currentIndex]))
            if !history.isEmpty {
                inputs.append(textInput("Conversation so far:\n\(history)"))
            }
        }

        for block in messages[currentIndex].content {
            switch block {
            case .content(.text(let text)) where !text.isEmpty:
                inputs.append(textInput(text))
            case .image(let base64, let mediaType):
                inputs.append(.object([
                    "type": "image",
                    "url": .string("data:\(mediaType);base64,\(base64)"),
                ]))
            default:
                continue
            }
        }
        guard !inputs.isEmpty else {
            throw CodexAppServerError.invalidResponse("the user message has no supported content")
        }
        return inputs
    }

    private func conversationHistory(_ messages: [AgentRequestMessage]) -> String {
        let transcript = messages.compactMap { message -> String? in
            let text = message.content.compactMap { block -> String? in
                guard case .content(.text(let text)) = block else { return nil }
                return text
            }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(text)"
        }.joined(separator: "\n\n")
        return String(transcript.suffix(20_000))
    }

    private func textInput(_ text: String) -> Value {
        .object([
            "type": "text",
            "text": .string(text),
            "text_elements": .array([]),
        ])
    }

    private func request(method: String, params: Value) async throws -> Value {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            do {
                try write(.object([
                    "method": .string(method),
                    "id": .int(id),
                    "params": params,
                ]))
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(method: String) throws {
        try write(.object(["method": .string(method)]))
    }

    private func write(_ value: Value) throws {
        guard let input else { throw CodexAppServerError.connectionClosed }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              let object = value.objectValue else {
            Log.agent.warning("ignored malformed Codex app-server message")
            return
        }

        if let id = object["id"]?.intValue, let pending = pendingResponses.removeValue(forKey: id) {
            if let error = object["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? "Codex request failed."
                pending.resume(throwing: CodexAppServerError.requestFailed(message))
            } else if let result = object["result"] {
                pending.resume(returning: result)
            } else {
                pending.resume(throwing: CodexAppServerError.invalidResponse("response omitted its result"))
            }
            return
        }

        guard let method = object["method"]?.stringValue else { return }
        if object["id"] != nil {
            handleServerRequest(object, method: method)
            return
        }
        guard let params = object["params"]?.objectValue else { return }
        handleNotification(method: method, params: params)
    }

    private func handleNotification(method: String, params: [String: Value]) {
        guard let threadID = params["threadId"]?.stringValue,
              var active = activeTurns[threadID] else { return }
        let eventTurnID = params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
        if let expected = active.turnID, let eventTurnID, expected != eventTurnID { return }

        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return }
            active.receivedText = true
            active.stream.yield(.textDelta(delta))
            activeTurns[threadID] = active
        case "item/completed":
            guard !active.receivedText,
                  let item = params["item"]?.objectValue,
                  item["type"]?.stringValue == "agentMessage",
                  let text = item["text"]?.stringValue,
                  !text.isEmpty else { return }
            active.receivedText = true
            active.stream.yield(.textDelta(text))
            activeTurns[threadID] = active
        case "turn/completed":
            let turn = params["turn"]?.objectValue
            switch turn?["status"]?.stringValue {
            case "completed":
                active.stream.yield(.messageStop(stopReason: .endTurn))
                finishTurn(threadID: threadID, result: .success(()))
            case "interrupted":
                finishTurn(threadID: threadID, result: .failure(.turnFailed("The Codex response was interrupted.")))
            case "failed":
                let message = turn?["error"]?.objectValue?["message"]?.stringValue
                    ?? "Codex could not complete this request."
                finishTurn(threadID: threadID, result: .failure(.turnFailed(message)))
            default:
                finishTurn(threadID: threadID, result: .failure(.invalidResponse("turn completed without a terminal status")))
            }
        case "error":
            guard params["willRetry"]?.boolValue == false else { return }
            let message = params["error"]?.objectValue?["message"]?.stringValue
                ?? "Codex could not complete this request."
            finishTurn(threadID: threadID, result: .failure(.turnFailed(message)))
        default:
            break
        }
    }

    private func handleServerRequest(_ object: [String: Value], method: String) {
        guard let id = object["id"] else { return }
        if method == "mcpServer/elicitation/request",
           let params = object["params"]?.objectValue,
           isCreatorStudioToolApproval(params) {
            try? write(.object([
                "id": id,
                "result": .object([
                    "action": "accept",
                    "content": .object([:]),
                    "_meta": .null,
                ]),
            ]))
            return
        }

        Log.agent.warning("rejected unsupported Codex app-server request: \(method)")
        try? write(.object([
            "id": id,
            "error": .object([
                "code": -32601,
                "message": .string("CreatorStudio Editor does not support \(method)."),
            ]),
        ]))
    }

    private func isCreatorStudioToolApproval(_ params: [String: Value]) -> Bool {
        guard params["serverName"]?.stringValue == "creatorstudio-editor",
              params["mode"]?.stringValue == "form",
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              activeTurns[threadID]?.turnID == turnID,
              let metadata = params["_meta"]?.objectValue,
              metadata["codex_approval_kind"]?.stringValue == "mcp_tool_call",
              let schema = params["requestedSchema"]?.objectValue,
              schema["type"]?.stringValue == "object",
              schema["properties"]?.objectValue?.isEmpty == true else {
            return false
        }
        return true
    }

    private func finishTurn(threadID: String, result: Result<Void, CodexAppServerError>) {
        guard let active = activeTurns.removeValue(forKey: threadID) else { return }
        switch result {
        case .success:
            active.completion.resume()
        case .failure(let error):
            active.completion.resume(throwing: error)
        }
    }

    private func connectionEnded() {
        guard process != nil || input != nil || isInitialized else { return }
        process = nil
        input = nil
        outputTask = nil
        isInitialized = false
        conversationThreads.removeAll()

        let error = CodexAppServerError.connectionClosed
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
        let turns = activeTurns.values
        activeTurns.removeAll()
        for turn in turns {
            turn.completion.resume(throwing: error)
        }
    }

    private nonisolated static func installedExecutableURL() async -> URL? {
        await Task.detached(priority: .utility) {
            executableURL()
        }.value
    }

    private nonisolated static func disabledMCPArguments() async -> [String] {
        await Task.detached(priority: .utility) {
            let configURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
            let prefix = "[mcp_servers."
            return config.components(separatedBy: .newlines).flatMap { line -> [String] in
                let header = line.trimmingCharacters(in: .whitespaces)
                guard header.hasPrefix(prefix), header.hasSuffix("]") else { return [] }
                let start = header.index(header.startIndex, offsetBy: prefix.count)
                let name = String(header[start..<header.index(before: header.endIndex)])
                guard !name.contains("."), name != "creatorstudio-editor" else { return [] }
                return ["-c", "mcp_servers.\(name).enabled=false"]
            }
        }.value
    }

    private nonisolated static func executableURL() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates = [
            environment["CODEX_CLI_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ].compactMap { $0 }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        let nvmRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            candidates.append(contentsOf: versions.map { $0.appendingPathComponent("bin/codex").path })
        }

        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
