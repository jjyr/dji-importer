import Foundation

enum PhotosImporter {
    static func importFile(_ fileURL: URL) -> PhotosImportResult {
        let posixPath = fileURL.standardizedFileURL.path
        let script = """
        tell application "Photos" to import POSIX file \(appleScriptStringLiteral(posixPath)) skip check duplicates true
        """

        let maxTotalWait = 15
        let waitStep = 5
        var totalWaited = 0
        var lastOutput = ""

        while true {
            let result = runAppleScript(script)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

            if result.exitCode == 0 {
                return PhotosImportResult(succeeded: true, message: output)
            }

            guard output.contains("AppleEvent timed out") else {
                return PhotosImportResult(succeeded: false, message: output)
            }

            lastOutput = output

            guard totalWaited < maxTotalWait else {
                return PhotosImportResult(succeeded: false, message: lastOutput)
            }

            Thread.sleep(forTimeInterval: TimeInterval(waitStep))
            totalWaited += waitStep
        }
    }

    private static func runAppleScript(_ script: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return (1, "Failed to start osascript: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return (process.terminationStatus, output + errorOutput)
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
