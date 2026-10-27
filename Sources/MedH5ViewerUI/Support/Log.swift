import Foundation
import os

/// The app's log (unified logging, subsystem `io.github.medh5-project.viewer`).
/// With `MEDH5_VIEWER_LOG=1` in the environment, messages are also written to
/// standard error (useful with `--snapshot`).
enum Log {
    private static let logger = Logger(subsystem: "io.github.medh5-project.viewer", category: "app")
    private static let echo = ProcessInfo.processInfo.environment["MEDH5_VIEWER_LOG"] == "1"

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        if echo { FileHandle.standardError.write(Data(("[viewer] " + text + "\n").utf8)) }
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        if echo { FileHandle.standardError.write(Data(("[viewer] error: " + text + "\n").utf8)) }
    }
}
