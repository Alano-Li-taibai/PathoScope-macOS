import CoreGraphics
import Foundation
import ImageIO

struct MRXSChannelMetadata: Equatable, Sendable {
    let id: String
    let name: String
    let storingChannel: Int
    let dataFilterLevel: String
    let red: Int
    let green: Int
    let blue: Int
    let brightness: Int
    let contrast: Int
}

struct MRXSMetadata {
    let slideID: String
    let tileCountX: Int
    let tileCountY: Int
    let imageDivisions: Int
    let zoomLevels: Int
    let micronsPerPixel: [Double]
    let tileWidths: [Int]
    let tileHeights: [Int]
    let overlapX: [Double]
    let overlapY: [Double]
    let concatExponents: [Int]
    let channels: [MRXSChannelMetadata]
    let dataFilterLevels: [String]
    let dataFiles: [String]
    let fillColorRGB: (Int, Int, Int)
    let positionRecordIndex: Int?
    let positionRecordIsCompressed: Bool

    static func parse(_ url: URL) throws -> MRXSMetadata {
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\u{feff}", with: "")
        var sections: [String: [String: String]] = [:]
        var currentSection: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                sections[currentSection!] = sections[currentSection!] ?? [:]
                continue
            }
            guard let currentSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            sections[currentSection, default: [:]][key] = value
        }

        guard let general = sections["GENERAL"],
              let hierarchical = sections["HIERARCHICAL"],
              let datafile = sections["DATAFILE"],
              let slideID = general["SLIDE_ID"],
              let tileCountX = Int(general["IMAGENUMBER_X"] ?? ""),
              let tileCountY = Int(general["IMAGENUMBER_Y"] ?? ""),
              let hierarchyCount = Int(hierarchical["HIER_COUNT"] ?? "") else {
            throw OpenSlidePreviewError.invalidMetadata("MRXS 的 Slidedat.ini 缺少必要字段")
        }
        let imageDivisions = max(Int(general["CameraImageDivisionsPerSide"] ?? "1") ?? 1, 1)

        func hierarchyIndex(named name: String) -> Int? {
            (0..<hierarchyCount).first { hierarchical["HIER_\($0)_NAME"] == name }
        }

        guard let zoomHierarchy = hierarchyIndex(named: "Slide zoom level"),
              let zoomLevels = Int(hierarchical["HIER_\(zoomHierarchy)_COUNT"] ?? "") else {
            throw OpenSlidePreviewError.invalidMetadata("MRXS 未找到缩放层级")
        }
        let filterHierarchy = hierarchyIndex(named: "Slide filter level")

        var mpp: [Double] = []
        var tileWidths: [Int] = []
        var tileHeights: [Int] = []
        var overlapX: [Double] = []
        var overlapY: [Double] = []
        var concatExponents: [Int] = []
        var fillRGB = (128, 128, 128)
        for level in 0..<zoomLevels {
            guard let sectionName = hierarchical["HIER_\(zoomHierarchy)_VAL_\(level)_SECTION"],
                  let section = sections[sectionName],
                  let levelMPP = Double(section["MICROMETER_PER_PIXEL_X"] ?? ""),
                  let tileWidth = Int(section["DIGITIZER_WIDTH"] ?? ""),
                  let tileHeight = Int(section["DIGITIZER_HEIGHT"] ?? ""),
                  let levelOverlapX = Double(section["OVERLAP_X"] ?? ""),
                  let levelOverlapY = Double(section["OVERLAP_Y"] ?? ""),
                  let concatExponent = Int(section["IMAGE_CONCAT_FACTOR"] ?? "") else {
                throw OpenSlidePreviewError.invalidMetadata("MRXS 第 \(level) 个缩放层信息不完整")
            }
            mpp.append(levelMPP)
            tileWidths.append(tileWidth)
            tileHeights.append(tileHeight)
            overlapX.append(levelOverlapX)
            overlapY.append(levelOverlapY)
            concatExponents.append(concatExponent)
            if level == 0, let packed = Int(section["IMAGE_FILL_COLOR_BGR"] ?? "") {
                fillRGB = (packed & 0xff, (packed >> 8) & 0xff, (packed >> 16) & 0xff)
            }
        }

        var channels: [MRXSChannelMetadata] = []
        if let filterHierarchy,
           let filterCount = Int(hierarchical["HIER_\(filterHierarchy)_COUNT"] ?? "") {
            for index in 0..<filterCount {
                guard let sectionName = hierarchical["HIER_\(filterHierarchy)_VAL_\(index)_SECTION"],
                      let section = sections[sectionName],
                      let name = section["FILTER_NAME"],
                      let storingChannel = Int(section["STORING_CHANNEL_NUMBER"] ?? ""),
                      let dataFilterLevel = section["DATA_IN_THIS_FILTER_LEVEL"] else { continue }
                channels.append(MRXSChannelMetadata(
                    id: "mrxs-\(index)-\(name)",
                    name: name,
                    storingChannel: storingChannel,
                    dataFilterLevel: dataFilterLevel,
                    red: Int(section["COLOR_R"] ?? "0") ?? 0,
                    green: Int(section["COLOR_G"] ?? "0") ?? 0,
                    blue: Int(section["COLOR_B"] ?? "0") ?? 0,
                    brightness: Int(section["BRIGHTNESS"] ?? "50") ?? 50,
                    contrast: Int(section["CONTRAST"] ?? "50") ?? 50
                ))
            }
        }

        let dataFilterLevels = Array(Set(channels.map(\.dataFilterLevel))).sorted {
            let lhs = Int($0.split(separator: "_").last ?? "0") ?? 0
            let rhs = Int($1.split(separator: "_").last ?? "0") ?? 0
            return lhs < rhs
        }
        let fileCount = Int(datafile["FILE_COUNT"] ?? "0") ?? 0
        let dataFiles = (0..<fileCount).compactMap { datafile["FILE_\($0)"] }
        let nonhierCount = Int(hierarchical["NONHIER_COUNT"] ?? "0") ?? 0
        var nonhierOffset = 0
        var vimslidePositionRecord: Int?
        var stitchingPositionRecord: Int?
        for index in 0..<nonhierCount {
            let name = hierarchical["NONHIER_\(index)_NAME"] ?? ""
            let count = Int(hierarchical["NONHIER_\(index)_COUNT"] ?? "0") ?? 0
            if name == "VIMSLIDE_POSITION_BUFFER" {
                vimslidePositionRecord = nonhierOffset
            } else if name == "StitchingIntensityLayer" {
                stitchingPositionRecord = nonhierOffset
            }
            nonhierOffset += count
        }
        let positionRecordIndex = vimslidePositionRecord ?? stitchingPositionRecord

        guard !channels.isEmpty, !dataFilterLevels.isEmpty, !dataFiles.isEmpty else {
            throw OpenSlidePreviewError.invalidMetadata("MRXS 未发现可读取的荧光通道")
        }
        return MRXSMetadata(
            slideID: slideID,
            tileCountX: tileCountX,
            tileCountY: tileCountY,
            imageDivisions: imageDivisions,
            zoomLevels: zoomLevels,
            micronsPerPixel: mpp,
            tileWidths: tileWidths,
            tileHeights: tileHeights,
            overlapX: overlapX,
            overlapY: overlapY,
            concatExponents: concatExponents,
            channels: channels,
            dataFilterLevels: dataFilterLevels,
            dataFiles: dataFiles,
            fillColorRGB: fillRGB,
            positionRecordIndex: positionRecordIndex,
            positionRecordIsCompressed: vimslidePositionRecord == nil && stitchingPositionRecord != nil
        )
    }
}

struct MRXSTileEntry: Sendable {
    let imageIndex: Int
    let offset: Int
    let size: Int
    let fileNumber: Int
}

enum MRXSNativeReader {
    static func readInt32(_ data: Data, at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else {
            throw OpenSlidePreviewError.invalidMetadata("MRXS Index.dat 指针越界")
        }
        let value = data.withUnsafeBytes { bytes -> UInt32 in
            let base = bytes.bindMemory(to: UInt8.self)
            return UInt32(base[offset])
                | (UInt32(base[offset + 1]) << 8)
                | (UInt32(base[offset + 2]) << 16)
                | (UInt32(base[offset + 3]) << 24)
        }
        return Int(Int32(bitPattern: value))
    }

    static func decodeRGBA(_ data: Data) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let created = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            // A bitmap CGContext already writes the decoded CGImage in top-to-bottom
            // memory order. Flipping here mirrors every MRXS JPEG vertically and, on
            // concatenated pyramid levels, swaps the camera subtiles during stitching.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? (width, height, pixels) : nil
    }

}
