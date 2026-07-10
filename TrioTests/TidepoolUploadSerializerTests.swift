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

/// One-shot async gate: `wait()` suspends until `open()`; opening before anyone waits is remembered.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
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

    @Test("Watchdog abandons a wedged chain so later uploads run again") func watchdogRecoversWedgedChain() async {
        let serializer = TidepoolUploadSerializer(watchdogLimit: 0.2)
        let started = Gate()

        // Head op wedges forever — simulates a completion lost while the app was suspended.
        await serializer.enqueue("wedged") { _ in
            await started.open()
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }

        // Only start the clock once the op is definitely running, then exceed the limit.
        await started.wait()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The next enqueue trips the watchdog; the new op must run on a fresh chain instead of
        // queueing forever behind the wedged one.
        let ran = await withCheckedContinuation { continuation in
            Task {
                await serializer.enqueue("fresh") { _ in continuation.resume(returning: true) }
            }
        }
        #expect(ran)
    }

    @Test("An abandoned operation sees a stale generation and bails out") func abandonedOperationSeesStaleGeneration() async {
        let serializer = TidepoolUploadSerializer(watchdogLimit: 0.2)
        let started = Gate()
        let release = Gate()

        async let observed: Bool = withCheckedContinuation { continuation in
            Task {
                await serializer.enqueue("orphan") { generation in
                    await started.open()
                    await release.wait() // held wedged past the watchdog limit
                    await continuation.resume(returning: serializer.isCurrent(generation))
                }
            }
        }

        await started.wait()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await serializer.recoverIfWedged() // watchdog abandons the chain

        // The resumed orphan must read its generation as stale.
        await release.open()
        #expect(await observed == false)
    }

    @Test("Watchdog leaves an idle chain alone") func watchdogIgnoresIdleChain() async {
        let serializer = TidepoolUploadSerializer(watchdogLimit: 0.1)

        let firstGeneration = await withCheckedContinuation { continuation in
            Task { await serializer.enqueue("first") { continuation.resume(returning: $0) } }
        }

        // Well past the limit, but with no operation running the watchdog must not trip.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await serializer.recoverIfWedged()

        let secondGeneration = await withCheckedContinuation { continuation in
            Task { await serializer.enqueue("second") { continuation.resume(returning: $0) } }
        }
        #expect(firstGeneration == secondGeneration)
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
