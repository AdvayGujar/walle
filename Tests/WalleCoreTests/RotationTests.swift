import Testing
@testable import WalleCore

@Suite("Rotation interval")
struct RotationTests {

    @Test func parsesBareSecondsAndUnits() {
        #expect(RotationInterval.parse("30")?.seconds == 30)
        #expect(RotationInterval.parse("30s")?.seconds == 30)
        #expect(RotationInterval.parse(" 5m ")?.seconds == 300)
        #expect(RotationInterval.parse("2h")?.seconds == 7200)
        #expect(RotationInterval.parse("2 hours")?.seconds == 7200)
        #expect(RotationInterval.parse("1 minute")?.seconds == 60)
    }

    @Test func rejectsMalformedAndZeroDurations() {
        for raw in ["", " ", "0", "0m", "-5m", "1.5h", "m", "10x", "10m5", "1h30m"] {
            #expect(RotationInterval.parse(raw) == nil, "\(raw) should be rejected")
        }
    }

    @Test func descriptionUsesTheShortestUnit() {
        #expect(RotationInterval(seconds: 5).description == "5s")
        #expect(RotationInterval(seconds: 60).description == "1m")
        #expect(RotationInterval(seconds: 300).description == "5m")
        #expect(RotationInterval(seconds: 3600).description == "1h")
        #expect(RotationInterval(seconds: 7200).description == "2h")
    }

    @Test func parsedDescriptionRoundTrips() throws {
        for raw in ["90s", "10m", "2h"] {
            let interval = try #require(RotationInterval.parse(raw))
            #expect(RotationInterval.parse(interval.description) == interval)
        }
    }
}
