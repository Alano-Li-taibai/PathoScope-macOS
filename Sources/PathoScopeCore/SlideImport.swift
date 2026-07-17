import Foundation

public enum SlideFormat: String, Codable, CaseIterable, Sendable {
    case mrxs
    case svs
    case ndpi
    case scn
    case tiff
    case qptiff
    case omeTiff

    public static func detect(filename: String) -> SlideFormat? {
        let name = filename.lowercased()
        if name.hasSuffix(".ome.tiff") || name.hasSuffix(".ome.tif") { return .omeTiff }
        if name.hasSuffix(".qptiff") { return .qptiff }
        if name.hasSuffix(".mrxs") { return .mrxs }
        if name.hasSuffix(".svs") { return .svs }
        if name.hasSuffix(".ndpi") { return .ndpi }
        if name.hasSuffix(".scn") { return .scn }
        if name.hasSuffix(".tiff") || name.hasSuffix(".tif") { return .tiff }
        return nil
    }
}

public struct ImportedSlide: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let format: SlideFormat
    public let companionDirectoryURL: URL?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        format: SlideFormat,
        companionDirectoryURL: URL? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.format = format
        self.companionDirectoryURL = companionDirectoryURL
    }

    public var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }
}

public enum SlideImportError: Error, Equatable, LocalizedError {
    case fileDoesNotExist(String)
    case unsupportedFormat(String)
    case missingMRXSCompanionDirectory(String)
    case incompleteMRXSCompanionDirectory(String, missing: [String])

    public var errorDescription: String? {
        switch self {
        case .fileDoesNotExist(let path):
            return "文件不存在：\(path)"
        case .unsupportedFormat(let name):
            return "暂不支持此格式：\(name)"
        case .missingMRXSCompanionDirectory(let name):
            return "未找到 MRXS 同名伴随目录：\(name)"
        case .incompleteMRXSCompanionDirectory(let name, let missing):
            return "MRXS 伴随目录不完整：\(name)，缺少 \(missing.joined(separator: "、"))"
        }
    }
}

public struct SlideImportService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(_ inputURL: URL) throws -> ImportedSlide {
        let url = inputURL.standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            throw SlideImportError.fileDoesNotExist(url.path)
        }
        guard let format = SlideFormat.detect(filename: url.lastPathComponent) else {
            throw SlideImportError.unsupportedFormat(url.lastPathComponent)
        }
        guard format == .mrxs else {
            return ImportedSlide(sourceURL: url, format: format)
        }

        let companion = url.deletingPathExtension()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: companion.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SlideImportError.missingMRXSCompanionDirectory(companion.lastPathComponent)
        }

        let required = ["Index.dat", "Slidedat.ini"]
        var missing = required.filter {
            !fileManager.fileExists(atPath: companion.appendingPathComponent($0).path)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: companion.path)) ?? []
        if !contents.contains(where: {
            $0.lowercased().hasPrefix("data") && $0.lowercased().hasSuffix(".dat")
        }) {
            missing.append("Data*.dat")
        }
        guard missing.isEmpty else {
            throw SlideImportError.incompleteMRXSCompanionDirectory(
                companion.lastPathComponent,
                missing: missing
            )
        }

        return ImportedSlide(
            sourceURL: url,
            format: format,
            companionDirectoryURL: companion
        )
    }
}
