import Darwin
import Foundation

/// Runs `nubb +canvas ...` when the binary is started that way, before the
/// app or the terminal core starts, so commands take milliseconds.
enum CanvasCLI {
    /// Runs the command and exits if `arguments` ask for `+canvas`.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "+canvas"), index >= 1 else { return }
        // Only an action in the first position counts, as in `nubb +canvas`,
        // so a file named "+canvas" passed to the app doesn't run this.
        guard index == 1 else { return }
        let args = Array(arguments[(index + 1)...])
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let result = CanvasCommands.run(args, context: CanvasCommandContext(cwd: cwd))
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        exit(result.exit)
    }
}
