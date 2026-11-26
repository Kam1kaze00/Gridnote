import CoreGraphics
import Foundation

struct ViewPosition: Codable, Equatable {
  var zoom: CGFloat = 1
  var x: CGFloat = 0
  var y: CGFloat = 0
  var tool: String?
  var selection: [UUID]?
  var editing: UUID?
  var cell: Int?
  var caret: Int?
  var selectionLength: Int?
}

struct NotebookSession: Codable {
  var lastNotebook: URL?
  var positions: [String: ViewPosition] = [:]
}

struct StorageError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

final class NotebookStorage {
  struct Opened {
    let notebook: Notebook
    let recovered: Bool
  }

  private let directory: URL
  private let queue = DispatchQueue(label: "app.gridnote.persistence", qos: .utility)
  private var pending: [URL: DispatchWorkItem] = [:]
  private var snapshots: [URL: Notebook] = [:]
  private let encoder = JSONEncoder()

  init(directory: URL? = nil) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    self.directory = directory ?? base.appendingPathComponent("Gridnote", isDirectory: true)
  }

  private var sessionURL: URL { directory.appendingPathComponent("Session.plist") }

  func loadSession() throws -> NotebookSession {
    guard FileManager.default.fileExists(atPath: sessionURL.path) else { return NotebookSession() }
    return try PropertyListDecoder().decode(
      NotebookSession.self, from: Data(contentsOf: sessionURL))
  }

  func saveSession(_ session: NotebookSession) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try PropertyListEncoder().encode(session).write(to: sessionURL, options: .atomic)
  }

  func localURL(named name: String) throws -> URL {
    let folder = directory.appendingPathComponent("Notebooks", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let filename = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(
      of: ":", with: "-")
    let stem = filename.isEmpty ? "Untitled Notebook" : filename
    var url = folder.appendingPathComponent(stem).appendingPathExtension("gridnote")
    var index = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(stem) \(index)").appendingPathExtension("gridnote")
      index += 1
    }
    return url
  }

  private func recoveryURL(for url: URL) -> URL {
    let key = Data(url.standardizedFileURL.path.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    // Split the path key so even lengthy notebook paths fit filesystem component limits.
    var result = directory.appendingPathComponent("Recovery", isDirectory: true)
    var suffix = Substring(key)
    while suffix.count > 100 {
      result.appendPathComponent(String(suffix.prefix(100)), isDirectory: true)
      suffix = suffix.dropFirst(100)
    }
    return result.appendingPathComponent(String(suffix)).appendingPathExtension("gridnote")
  }

  private func read(_ url: URL) throws -> Notebook {
    let data = try Data(contentsOf: url)
    let legacy = data.starts(with: Data("bplist".utf8)) || data.starts(with: Data("<?xml".utf8))
    var notebook =
      legacy
      ? try PropertyListDecoder().decode(Notebook.self, from: data)
      : try JSONDecoder().decode(Notebook.self, from: data)
    if legacy && notebook.sourcePDF != nil { notebook.originalPDFScale = true }
    guard notebook.version == 1 else {
      throw StorageError("This notebook requires a newer version of Gridnote.")
    }
    let limit = paperSize.height * 100_000
    func coordinate(_ value: CGFloat) -> Bool { value.isFinite && abs(value) <= limit }
    func validFrame(_ f: CGRect) -> Bool {
      [f.origin.x, f.origin.y, f.size.width, f.size.height].allSatisfy(coordinate)
        && f.size.width > 0 && f.size.height > 0 && f.maxY < limit
    }
    guard (1...100000).contains(notebook.minimumPages ?? 1), notebook.sourcePages >= 0,
      notebook.sourcePages <= 100_000,
      notebook.sourcePageMap.map({
        $0.count == notebook.sourcePages && $0.allSatisfy({ (-1..<100_000).contains($0) })
      }) ?? true,
      (notebook.pagePaper ?? [:]).keys.allSatisfy({ (0..<100_000).contains($0) }),
      Set(notebook.objects.map(\.id)).count == notebook.objects.count,
      notebook.objects.allSatisfy({ object in
        guard validFrame(object.frame), object.layoutFrame.map(validFrame) ?? true else { return false }
        if case .ink(let points, _) = object.content {
          return !points.isEmpty && points.allSatisfy {
            coordinate($0.position.x) && coordinate($0.position.y) && coordinate($0.radius) && $0.radius > 0
          }
        }
        return true
      })
    else { throw StorageError("This notebook contains invalid page coordinates.") }
    guard notebook.objects.allSatisfy({ o in
        if case .text(_, _, let size) = o.content, !(size > 0 && size <= 1_000_000) { return false }
        guard let grid = o.table else { return true }
        return (1...40).contains(grid.rows) && (1...16).contains(grid.columns)
          && grid.cells.count == grid.rows * grid.columns
          && (grid.formats ?? [:]).allSatisfy { key, f in
            let rc = key.split(separator: ":", omittingEmptySubsequences: false)
            guard rc.count == 2, let row = Int(rc[0]), let column = Int(rc[1]),
              key == "\(row):\(column)" else { return false }
            return (0..<grid.rows).contains(row) && (0..<grid.columns).contains(column)
              && f.size > 0 && f.size <= 1_000_000 && (0...7).contains(f.traits)
              && [f.color.r, f.color.g, f.color.b].allSatisfy { (0...1).contains($0) }
          }
      })
    else { throw StorageError("This notebook contains invalid table or page data.") }
    return notebook
  }

  func open(_ url: URL, recovering: Bool = false) throws -> Opened {
    try queue.sync {
      let primary: Result<Notebook, Error> = Result { try read(url) }
      if recovering, let recovery = try? read(recoveryURL(for: url)) {
        switch primary {
        case .success(let notebook):
          if recovery.id == notebook.id && recovery.revision > notebook.revision {
            return Opened(notebook: recovery, recovered: true)
          }
        case .failure:
          return Opened(notebook: recovery, recovered: true)
        }
      }
      return Opened(notebook: try primary.get(), recovered: false)
    }
  }

  private func write(_ notebook: Notebook, to url: URL) throws {
    let bytes = try encoder.encode(notebook)
    let recovery = recoveryURL(for: url)
    var recoveryFailure: Error?
    do {
      try FileManager.default.createDirectory(
        at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: recovery, options: .atomic)
    } catch { recoveryFailure = error }
    do { try bytes.write(to: url, options: .atomic) } catch {
      if recoveryFailure == nil {
        throw StorageError(
          "Gridnote couldn’t save the notebook. A recovery copy is on this Mac. \(error.localizedDescription)"
        )
      }
      throw StorageError(
        "Gridnote couldn’t save the notebook or its recovery copy. \(error.localizedDescription)")
    }
    if let recoveryFailure {
      throw StorageError(
        "The notebook was saved, but Gridnote couldn’t update its recovery copy. \(recoveryFailure.localizedDescription)"
      )
    }
  }

  func schedule(
    _ notebook: Notebook, to url: URL, completion: @escaping (UInt64, Result<Void, Error>) -> Void
  ) {
    queue.async {
      self.snapshots[url] = notebook
      if self.pending[url] != nil { return }
      let job = DispatchWorkItem {
        self.pending.removeValue(forKey: url)
        guard let snapshot = self.snapshots.removeValue(forKey: url) else { return }
        let result = Result { try self.write(snapshot, to: url) }
        DispatchQueue.main.async { completion(snapshot.revision, result) }
      }
      self.pending[url] = job
      self.queue.asyncAfter(deadline: .now() + 0.18, execute: job)
    }
  }

  func saveNow(_ notebook: Notebook, to url: URL) throws {
    try queue.sync {
      pending.removeValue(forKey: url)?.cancel()
      snapshots.removeValue(forKey: url)
      try write(notebook, to: url)
    }
  }
}
