import XCTest
@testable import DJIImporter

final class BatchTunerTests: XCTestCase {
    func testConvergesNearSimulatedOptimumWithRandomNoise() {
        let optimum = Double(BatchTuner.gigabyte)
        var random = SeededRandomNumberGenerator(seed: 0xD51_2026)
        var tuner = BatchTuner(
            initialLimits: BatchLimits(
                byteLimit: 128 * BatchTuner.megabyte,
                fileLimit: 20,
                maxVideoFileLimit: 2
            ),
            minimumLimits: BatchLimits(
                byteLimit: 32 * BatchTuner.megabyte,
                fileLimit: 1,
                maxVideoFileLimit: 1
            ),
            maximumLimits: BatchLimits(
                byteLimit: 4 * BatchTuner.gigabyte,
                fileLimit: 300,
                maxVideoFileLimit: 3
            ),
            threshold: 0.05
        )

        for _ in 0..<120 {
            let bytes = tuner.limits.byteLimit
            let throughput = simulatedThroughput(
                forByteLimit: bytes,
                optimum: optimum,
                random: &random
            )
            tuner.observe(bytes: bytes, seconds: Double(bytes) / throughput)
        }

        let ratio = Double(tuner.bestLimits.byteLimit) / optimum
        XCTAssertGreaterThan(ratio, 0.65)
        XCTAssertLessThan(ratio, 1.35)
    }

    func testFivePercentImprovementContinuesSameDirection() {
        var tuner = BatchTuner(
            initialLimits: BatchLimits(
                byteLimit: 100 * BatchTuner.megabyte,
                fileLimit: 10,
                maxVideoFileLimit: 2
            ),
            threshold: 0.05
        )

        tuner.observe(bytes: 100, seconds: 1.0)
        let firstTrial = tuner.limits
        tuner.observe(bytes: 106, seconds: 1.0)

        XCTAssertEqual(tuner.direction, .larger)
        XCTAssertGreaterThan(tuner.limits.byteLimit, firstTrial.byteLimit)
    }

    func testFivePercentRegressionRestoresBestAndReversesDirection() {
        var tuner = BatchTuner(
            initialLimits: BatchLimits(
                byteLimit: 100 * BatchTuner.megabyte,
                fileLimit: 10,
                maxVideoFileLimit: 2
            ),
            threshold: 0.05
        )

        tuner.observe(bytes: 100, seconds: 1.0)
        tuner.observe(bytes: 110, seconds: 1.0)
        let bestBeforeRegression = tuner.bestLimits

        tuner.observe(bytes: 90, seconds: 1.0)

        XCTAssertEqual(tuner.direction, .smaller)
        XCTAssertLessThanOrEqual(tuner.limits.byteLimit, bestBeforeRegression.byteLimit)
    }

    func testSubFivePercentSlowdownIsTreatedAsNoise() {
        var tuner = BatchTuner(
            initialLimits: BatchLimits(
                byteLimit: 100 * BatchTuner.megabyte,
                fileLimit: 10,
                maxVideoFileLimit: 2
            ),
            threshold: 0.05
        )

        tuner.observe(bytes: 100, seconds: 1.0)
        let trialAfterFirstObservation = tuner.limits
        tuner.observe(bytes: 98, seconds: 1.0)

        XCTAssertEqual(tuner.direction, .larger)
        XCTAssertGreaterThan(tuner.limits.byteLimit, trialAfterFirstObservation.byteLimit)
    }

    private func simulatedThroughput(
        forByteLimit byteLimit: Int64,
        optimum: Double,
        random: inout SeededRandomNumberGenerator
    ) -> Double {
        let distance = log(Double(byteLimit) / optimum)
        let curve = exp(-pow(distance / 0.72, 2))
        let noise = 1 + random.nextUnitDouble(in: -0.02...0.02)
        return 120_000_000 * (0.25 + 0.75 * curve) * noise
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextUnitDouble(in range: ClosedRange<Double>) -> Double {
        let value = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + value * (range.upperBound - range.lowerBound)
    }
}
