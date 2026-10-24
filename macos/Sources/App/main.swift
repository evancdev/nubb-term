import AppKit
import Cocoa
import NubbKit

// Initialize Nubb global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if nubb_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != NUBB_SUCCESS {
    Nubb.logger.critical("nubb_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Nubb.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Nubb failed to initialize! If you're executing Nubb from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `nubb +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `nubb +version`.
nubb_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
