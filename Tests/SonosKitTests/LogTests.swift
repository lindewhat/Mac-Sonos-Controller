import Testing
import Foundation
@testable import SonosKit

private func temporaryLog(maxBytes: Int = 1_000_000, verbose: Bool = false) -> Log {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-test-\(UUID().uuidString)")
    return Log(fileURL: folder.appendingPathComponent("Test.log"), maxBytes: maxBytes, verbose: verbose)
}

@Test func aLineHasTimeLevelAreaAndText() {
    let date = Date(timeIntervalSince1970: 0)
    let line = Log.line("ERROR", "sonos", "Pause failed:\nno answer", at: date)
    #expect(line.hasSuffix(" ERROR sonos Pause failed: no answer\n")) // one line, however the text was written
    #expect(line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} "#, options: .regularExpression) != nil)
}

@Test func linesAreAppendedInOrderAndTheFolderIsCreated() throws {
    let log = temporaryLog()
    log.error("sonos", "first")
    log.warn("app", "second")
    log.info("app", "third")
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].hasSuffix("ERROR sonos first") && lines[1].hasSuffix("WARN app second") && lines[2].hasSuffix("INFO app third"))
}

@Test func tracingOnlyHappensInVerboseMode() throws {
    let quiet = temporaryLog(verbose: false)
    quiet.trace("sonos", "routine")
    #expect(!FileManager.default.fileExists(atPath: quiet.fileURL.path))
    let chatty = temporaryLog(verbose: true)
    chatty.trace("sonos", "routine")
    #expect(try String(contentsOf: chatty.fileURL, encoding: .utf8).contains("TRACE sonos routine"))
}

@Test func theFileStaysSmallByKeepingOneOlderCopy() throws {
    let log = temporaryLog(maxBytes: 200)
    for i in 0..<30 { log.info("app", "line number \(i) with some padding text") }
    let older = log.fileURL.appendingPathExtension("1")
    #expect(FileManager.default.fileExists(atPath: older.path))
    #expect(!FileManager.default.fileExists(atPath: log.fileURL.appendingPathExtension("2").path))
    let size = (try FileManager.default.attributesOfItem(atPath: log.fileURL.path))[.size] as? Int ?? 0
    #expect(size < 400) // the current file restarted after the older one was set aside
}

@Test func anUnwritableLocationIsIgnoredNotACrash() {
    let log = Log(fileURL: URL(fileURLWithPath: "/dev/null/impossible/Test.log"))
    log.error("sonos", "nowhere to write") // must simply return
}
