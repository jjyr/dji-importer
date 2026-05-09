import Foundation

struct BatchLimits: Equatable {
    var byteLimit: Int64
    var fileLimit: Int
    var maxVideoFileLimit: Int
}

struct BatchTuner {
    enum Direction {
        case larger
        case smaller

        mutating func reverse() {
            self = self == .larger ? .smaller : .larger
        }
    }

    static let megabyte: Int64 = 1024 * 1024
    static let gigabyte: Int64 = 1024 * megabyte

    private let threshold: Double
    private let growthFactor: Double
    private let shrinkFactor: Double
    private let minimumLimits: BatchLimits
    private let maximumLimits: BatchLimits

    private(set) var limits: BatchLimits
    private(set) var bestLimits: BatchLimits
    private(set) var bestThroughput: Double = 0
    private(set) var direction: Direction = .larger
    private(set) var lastThroughput: Double?

    init(
        initialLimits: BatchLimits = BatchLimits(
            byteLimit: 512 * Self.megabyte,
            fileLimit: 50,
            maxVideoFileLimit: 3
        ),
        minimumLimits: BatchLimits = BatchLimits(
            byteLimit: 64 * Self.megabyte,
            fileLimit: 1,
            maxVideoFileLimit: 1
        ),
        maximumLimits: BatchLimits = BatchLimits(
            byteLimit: 4 * Self.gigabyte,
            fileLimit: 300,
            maxVideoFileLimit: 3
        ),
        threshold: Double = 0.05,
        growthFactor: Double = 1.25,
        shrinkFactor: Double = 0.8
    ) {
        self.limits = initialLimits
        self.bestLimits = initialLimits
        self.minimumLimits = minimumLimits
        self.maximumLimits = maximumLimits
        self.threshold = threshold
        self.growthFactor = growthFactor
        self.shrinkFactor = shrinkFactor
    }

    mutating func observe(bytes: Int64, seconds: TimeInterval) {
        guard bytes > 0, seconds > 0 else {
            return
        }

        let throughput = Double(bytes) / seconds

        if throughput > bestThroughput {
            bestThroughput = throughput
            bestLimits = limits
        }

        guard let lastThroughput else {
            self.lastThroughput = throughput
            adjustSameDirection()
            return
        }

        // Treat changes within the threshold as noise. Only a clear slowdown
        // reverts to the best known limits and probes the opposite direction.
        if throughput <= lastThroughput * (1 - threshold) {
            limits = bestLimits
            direction.reverse()
            self.lastThroughput = max(bestThroughput, throughput)
            adjustSameDirection()
        } else {
            self.lastThroughput = throughput
            adjustSameDirection()
        }
    }

    private mutating func adjustSameDirection() {
        switch direction {
        case .larger:
            limits = scaledLimits(by: growthFactor)
        case .smaller:
            limits = scaledLimits(by: shrinkFactor)
        }
    }

    private func scaledLimits(by factor: Double) -> BatchLimits {
        BatchLimits(
            byteLimit: clamp(
                scaledInt64(limits.byteLimit, by: factor),
                minimum: minimumLimits.byteLimit,
                maximum: maximumLimits.byteLimit
            ),
            fileLimit: clamp(
                scaledInt(limits.fileLimit, by: factor),
                minimum: minimumLimits.fileLimit,
                maximum: maximumLimits.fileLimit
            ),
            maxVideoFileLimit: clamp(
                scaledInt(limits.maxVideoFileLimit, by: factor),
                minimum: minimumLimits.maxVideoFileLimit,
                maximum: maximumLimits.maxVideoFileLimit
            )
        )
    }

    private func scaledInt64(_ value: Int64, by factor: Double) -> Int64 {
        let scaled = Int64((Double(value) * factor).rounded())
        if factor > 1, scaled == value {
            return value + 1
        }
        if factor < 1, scaled == value {
            return value - 1
        }
        return scaled
    }

    private func scaledInt(_ value: Int, by factor: Double) -> Int {
        let scaled = Int((Double(value) * factor).rounded())
        if factor > 1, scaled == value {
            return value + 1
        }
        if factor < 1, scaled == value {
            return value - 1
        }
        return scaled
    }

    private func clamp<T: Comparable>(_ value: T, minimum: T, maximum: T) -> T {
        min(max(value, minimum), maximum)
    }
}
