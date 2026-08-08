import XCTest
@testable import MacWake

@MainActor
final class AsyncCopyControllerTests: XCTestCase {
    // Short so tests run fast; the acceptance criteria are about the state sequence, not
    // the exact production delay.
    private func makeController() -> AsyncCopyController {
        AsyncCopyController(revertDelayNanoseconds: 60_000_000)
    }

    func testShowsRunningWhileTheCallIsInFlight() async {
        let controller = makeController()
        XCTAssertEqual(controller.state, .idle)

        let task = Task {
            await controller.run {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return "report"
            }
        }
        // Give run() a moment to flip to .running before the slow work finishes.
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(controller.state, .running, "must show progress, not look frozen")

        await task.value
        // run() returns as soon as the state becomes .copied — deterministic, not a race
        // against the revert timer.
        XCTAssertEqual(controller.state, .copied)
    }

    func testASecondRequestCannotStartWhileOneIsRunning() async {
        let controller = makeController()
        var callCount = 0

        let first = Task {
            await controller.run {
                callCount += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
                return "first"
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(controller.state, .running)

        // Fired while the first call is still in flight — must be a no-op.
        await controller.run { callCount += 1; return "second" }
        XCTAssertEqual(callCount, 1, "an overlapping request must not start new work")

        await first.value
    }

    func testRevertsToIdleAfterTheSuccessDisplay() async {
        let controller = makeController()
        await controller.run { "report" }
        XCTAssertEqual(controller.state, .copied)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .idle, "must become reusable, not stay on Copied forever")
    }

    func testRepeatingTheActionRunsAFreshCycleAndUpdatesTheResult() async {
        let controller = makeController()
        var results: [String] = []

        await controller.run { "first" } onSuccess: { results.append($0) }
        XCTAssertEqual(controller.state, .copied)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .idle)

        await controller.run { "second" } onSuccess: { results.append($0) }
        XCTAssertEqual(controller.state, .copied)
        XCTAssertEqual(results, ["first", "second"])
    }

    func testCopiedStateAllowsImmediatelyStartingAgain() async {
        // canStart must not force waiting out the success display before a new run.
        let controller = makeController()
        await controller.run { "first" }
        XCTAssertEqual(controller.state, .copied)
        XCTAssertTrue(AsyncCopyState.copied.canStart)

        await controller.run { "second" }
        XCTAssertEqual(controller.state, .copied)
    }

    func testIdleAndRunningCanStartValues() {
        XCTAssertTrue(AsyncCopyState.idle.canStart)
        XCTAssertFalse(AsyncCopyState.running.canStart)
    }
}
