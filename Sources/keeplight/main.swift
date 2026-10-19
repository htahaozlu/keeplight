import Foundation

import DisplayCore

// Dotpitch's state folder becomes Keeplight's before the first command reads it (once).
LegacyData.migrate()
exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
