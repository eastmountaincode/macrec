import Foundation

public struct RecordingSession: Sendable {
    public let id: UUID
    public let startedAt: Date
    public let title: String?
    public let fileStem: String
    public let directory: URL
    public let micFile: URL
    public let systemFile: URL

    public init(directory: URL, title: String? = nil, startedAt: Date = Date()) {
        let id = UUID()
        self.id = id
        self.startedAt = startedAt
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let stamp = RecordingSession.timestampFormatter.string(from: startedAt)
        let slug = RecordingSession.slug(for: title)
        let stem = [stamp, slug].compactMap { $0 }.joined(separator: "-")
        let folderName = "macrec-\(stem)"
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        self.fileStem = stem
        self.directory = folder
        self.micFile = folder.appendingPathComponent("\(stem)-me.m4a")
        self.systemFile = folder.appendingPathComponent("\(stem)-call.m4a")
    }

    public static func previewFileNames(title: String?) -> (mic: String, system: String) {
        let slug = slug(for: title)
        let stem = ["YYYY-MM-DD_HH-mm-ss", slug].compactMap { $0 }.joined(separator: "-")
        return ("\(stem)-me.m4a", "\(stem)-call.m4a")
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func slug(for title: String?) -> String? {
        guard let title = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .nilIfEmpty else {
            return nil
        }

        let allowed = CharacterSet.alphanumerics
        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = false

        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }
        }

        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
