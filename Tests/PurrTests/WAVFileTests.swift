import Foundation
import Testing

@testable import Purr

struct WAVFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("purr-wavtest-\(UUID().uuidString).wav")
    }

    @Test func roundTripPreservesSamples() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A 100 Hz ramp keeps every value distinct so an off-by-one or
        // channel-count bug shifts data and fails the comparison.
        let samples: [Float] = (0..<1600).map { Float($0) / 1600.0 - 0.5 }
        try WAVFile.write(samples: samples, to: url)
        let back = try WAVFile.read(url: url)
        #expect(back.count == samples.count)
        #expect(zip(back, samples).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func readRejectsMissingFile() {
        let url = tempURL()
        #expect(throws: (any Error).self) { try WAVFile.read(url: url) }
    }
}
