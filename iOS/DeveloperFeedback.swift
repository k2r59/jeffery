import Foundation

/// Remarques dictées à Jeffrey pour le développeur, écrites dans Documents/feedback.md (récupérable depuis le Mac).
enum DeveloperFeedback {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("feedback.md")
    }
    static func append(_ text: String, context: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "- \(stamp) — \(text)\n  contexte : \(context)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? ("# Retours dictés à Jeffrey\n\n" + entry).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
