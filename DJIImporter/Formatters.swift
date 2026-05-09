import Foundation

enum AppFormatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

extension Int64 {
    var fileSizeText: String {
        AppFormatters.byteCount.string(fromByteCount: self)
    }
}
