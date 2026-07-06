import Foundation
import Testing

@testable import Barktor

struct DictationEntryStatusTests {
    // Minimal JSON for a legacy entry (no sourceFilename, pre-queue status).
    // Dates use the default strategy (seconds since reference date, Double).
    private func entryJSON(status: String) -> Data {
        Data(
            """
            {"id":"11111111-2222-3333-4444-555555555555","date":0,"duration":1.5,
             "engineUsed":"parakeet","mode":"batch","status":"\(status)"}
            """.utf8)
    }

    @Test func unknownStatusDecodesAsFailedInsteadOfThrowing() throws {
        let entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "hologram"))
        #expect(entry.status == .failed)
    }

    @Test func queuedAndTranscribingRoundTrip() throws {
        for status in [DictationEntry.Status.queued, .transcribing] {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(DictationEntry.Status.self, from: data) == status)
        }
    }

    @Test func legacyJSONWithoutSourceFilenameDecodesNil() throws {
        let entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "ok"))
        #expect(entry.sourceFilename == nil)
    }

    @Test func sourceFilenameRoundTrips() throws {
        var entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "ok"))
        entry.sourceFilename = "nota-voz.m4a"
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(DictationEntry.self, from: data)
        #expect(back.sourceFilename == "nota-voz.m4a")
    }
}
