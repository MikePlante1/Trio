import Foundation
import Testing

@testable import Trio

// MARK: - Upload serialization tests

/// Tracks the start order and peak concurrency of serialized operations.
private actor Recorder {
    private(set) var order: [Int] = []
    private var active = 0
    private(set) var maxActive = 0

    func begin(_ index: Int) {
        order.append(index)
        active += 1
        maxActive = max(maxActive, active)
    }

    func end() {
        active -= 1
    }
}

@Suite("Tidepool upload serialization") struct TidepoolUploadSerializerTests {
    /// Operations must run one at a time, in enqueue order. If two ever overlapped, `maxActive`
    /// would exceed 1; if the chain reordered, `order` wouldn't be 0..<count.
    @Test("Serializer runs operations one at a time, in order") func serializesInOrder() async {
        let serializer = TidepoolUploadSerializer()
        let recorder = Recorder()
        let count = 10

        for index in 0 ..< count {
            await serializer.enqueue("op-\(index)") { _ in
                await recorder.begin(index)
                // Yield instead of sleeping: a real-time sleep makes the stress depend on machine
                // speed (and can mask a race on a fast box). `Task.yield()` deterministically hands
                // the scheduler a chance to run any (incorrectly) concurrent operation, so a broken
                // serializer would push `maxActive` above 1 here without any wall-clock dependence.
                await Task.yield()
                await recorder.end()
            }
        }

        // Enqueue a sentinel last and await it; the chain guarantees it runs after all prior work.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await serializer.enqueue("sentinel") { _ in continuation.resume() } }
        }

        #expect(await recorder.order == Array(0 ..< count))
        #expect(await recorder.maxActive == 1)
    }

    @Test("awaitUpload returns the completion's result") func awaitUploadReturnsResult() async {
        let result = await BaseTidepoolManager.awaitUpload("test", timeout: 5) { completion in
            completion(.success(true))
        }

        guard case .success(true) = result else {
            Issue.record("expected .success(true), got \(result)")
            return
        }
    }

    @Test("awaitUpload times out when the completion never fires") func awaitUploadTimesOut() async {
        let result = await BaseTidepoolManager.awaitUpload("test", timeout: 0.2) { _ in
            // Never call the completion: simulates a wedged network/auth call.
        }

        guard case let .failure(error) = result,
              let uploadError = error as? TidepoolUploadError,
              case .timedOut = uploadError
        else {
            Issue.record("expected .timedOut failure, got \(result)")
            return
        }
    }

    @Test("A late completion after timeout is ignored, not a crash") func lateCompletionIsIgnored() async {
        var storedCompletion: ((Result<Bool, Error>) -> Void)?

        let result = await BaseTidepoolManager.awaitUpload("test", timeout: 0.2) { completion in
            storedCompletion = completion // fire it after the timeout below
        }

        guard case .failure = result else {
            Issue.record("expected timeout failure, got \(result)")
            return
        }

        // Resolving the captured completion after the one-shot guard already resumed must be a no-op.
        storedCompletion?(.success(true))
    }
}
