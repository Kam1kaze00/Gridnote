import AppKit

struct ChatGPTReply: Decodable {
  var connected = false
  var answer: String?
  var error: String?
}

// The bundled helper owns OAuth and protected account storage. Its only output is a user-facing reply.
final class ChatGPTCall {
  private let process = Process()
  private let lock = NSLock()
  private var canceled = false

  func cancel() {
    lock.lock()
    canceled = true
    if process.isRunning { process.terminate() }
    lock.unlock()
  }

  @discardableResult
  static func send(_ request: [String: String], then: @escaping (ChatGPTReply) -> Void) -> ChatGPTCall {
    let call = ChatGPTCall()
    DispatchQueue.global(qos: .userInitiated).async {
      let reply = call.run(request)
      DispatchQueue.main.async { then(reply) }
    }
    return call
  }

  private func run(_ request: [String: String]) -> ChatGPTReply {
    let input = Pipe(), output = Pipe()
    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "GridnoteChatGPT") else {
      return ChatGPTReply(error: "This build is missing its ChatGPT component.")
    }
    do {
      let data = try JSONEncoder().encode(request)
      process.executableURL = helper
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      lock.lock()
      if canceled { lock.unlock(); return ChatGPTReply(error: "Canceled.") }
      do { try process.run() } catch { lock.unlock(); throw error }
      lock.unlock()
      let writer = input.fileHandleForWriting
      _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
      defer { try? writer.close() }
      try writer.write(contentsOf: data)
      try writer.close()
      let result = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return try JSONDecoder().decode(ChatGPTReply.self, from: result)
    } catch {
      cancel()
      return ChatGPTReply(error: "The ChatGPT request was interrupted. Click Ask AI to try again.")
    }
  }
}
