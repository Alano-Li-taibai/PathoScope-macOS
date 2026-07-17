import Foundation

public struct ScaleBarMeasurement: Equatable, Sendable {
    public let microns: Double
    public let points: Double

    public var label: String {
        if microns >= 1000 {
            return String(format: microns >= 10_000 ? "%.0f mm" : "%.1f mm", microns / 1000)
        }
        if microns >= 10 { return String(format: "%.0f µm", microns) }
        if microns >= 1 { return String(format: "%.1f µm", microns) }
        return String(format: "%.2f µm", microns)
    }
}

public enum ScaleBarCalculator {
    public static func measurement(
        micronsPerImagePixel: Double,
        pointsPerImagePixel: Double,
        maximumPoints: Double
    ) -> ScaleBarMeasurement? {
        guard micronsPerImagePixel > 0, pointsPerImagePixel > 0, maximumPoints >= 20 else { return nil }
        let maximumMicrons = maximumPoints * micronsPerImagePixel / pointsPerImagePixel
        guard maximumMicrons > 0 else { return nil }
        let exponent = floor(log10(maximumMicrons))
        let magnitude = pow(10, exponent)
        let normalized = maximumMicrons / magnitude
        let step: Double
        if normalized >= 5 { step = 5 }
        else if normalized >= 2 { step = 2 }
        else { step = 1 }
        let microns = step * magnitude
        return ScaleBarMeasurement(
            microns: microns,
            points: microns / micronsPerImagePixel * pointsPerImagePixel
        )
    }
}
