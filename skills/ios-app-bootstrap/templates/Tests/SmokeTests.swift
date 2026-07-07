import XCTest

/// Smoke test — exists so the scheme has a test action out of the box and the
/// required `Tests` CI check can go green on day one (without it `xcodebuild
/// test` exits 66, "not configured for the test action", and blocks every
/// feature→main PR). Replace/grow this into the real unit + snapshot suite as
/// the app gains code — the testability seams in §7 are what make that cheap.
final class SmokeTests: XCTestCase {
    func testItRuns() {
        XCTAssertTrue(true)
    }
}
