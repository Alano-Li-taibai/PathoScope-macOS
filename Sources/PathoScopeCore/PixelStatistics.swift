import Foundation

public struct ROIIntensityStatistics: Codable, Equatable, Sendable {
    public let pixelCount: Int
    public let mean: Double
    public let median: Double
    public let integratedIntensity: Double
    public let positiveAreaFraction: Double
    public let positiveThreshold: Double
}

public struct ROIBackgroundCorrectedStatistics: Codable, Equatable, Sendable {
    public let raw: ROIIntensityStatistics
    public let backgroundPixelCount: Int
    public let backgroundMean: Double
    public let backgroundCorrectedMean: Double

    public init(
        raw: ROIIntensityStatistics,
        backgroundPixelCount: Int,
        backgroundMean: Double,
        backgroundCorrectedMean: Double
    ) {
        self.raw = raw
        self.backgroundPixelCount = backgroundPixelCount
        self.backgroundMean = backgroundMean
        self.backgroundCorrectedMean = backgroundCorrectedMean
    }
}

public enum StatisticsError: Error, Equatable {
    case emptyPixels
    case nonFiniteValue
    case invalidPixelArea
}

public enum PixelStatistics {
    /// Computes raw statistics. Display gamma, contrast and pseudocolor must never be applied here.
    public static func compute(
        pixels: [Double],
        positiveThreshold: Double,
        pixelAreaSquareMicrons: Double = 1
    ) throws -> ROIIntensityStatistics {
        guard !pixels.isEmpty else { throw StatisticsError.emptyPixels }
        guard pixels.allSatisfy(\.isFinite), positiveThreshold.isFinite else {
            throw StatisticsError.nonFiniteValue
        }
        guard pixelAreaSquareMicrons > 0, pixelAreaSquareMicrons.isFinite else {
            throw StatisticsError.invalidPixelArea
        }

        let sorted = pixels.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }
        let positiveCount = sorted.lazy.filter { $0 >= positiveThreshold }.count

        return ROIIntensityStatistics(
            pixelCount: count,
            mean: sum / Double(count),
            median: median,
            integratedIntensity: sum * pixelAreaSquareMicrons,
            positiveAreaFraction: Double(positiveCount) / Double(count),
            positiveThreshold: positiveThreshold
        )
    }

    /// Computes raw ROI statistics together with a local-background correction.
    /// Both arrays must contain stored channel intensities, never display-adjusted values.
    public static func computeBackgroundCorrected(
        roiPixels: [Double],
        backgroundPixels: [Double],
        positiveThreshold: Double,
        pixelAreaSquareMicrons: Double = 1
    ) throws -> ROIBackgroundCorrectedStatistics {
        let raw = try compute(
            pixels: roiPixels,
            positiveThreshold: positiveThreshold,
            pixelAreaSquareMicrons: pixelAreaSquareMicrons
        )
        guard !backgroundPixels.isEmpty else { throw StatisticsError.emptyPixels }
        guard backgroundPixels.allSatisfy(\.isFinite) else {
            throw StatisticsError.nonFiniteValue
        }
        let backgroundMean = backgroundPixels.reduce(0, +) / Double(backgroundPixels.count)
        return ROIBackgroundCorrectedStatistics(
            raw: raw,
            backgroundPixelCount: backgroundPixels.count,
            backgroundMean: backgroundMean,
            backgroundCorrectedMean: raw.mean - backgroundMean
        )
    }
}
