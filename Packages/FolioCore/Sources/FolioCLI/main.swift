import FolioAgent
import Foundation

// folio-cli: Folio's AI interface — `folio-cli mcp` for MCP clients, other commands for shells.
let status = await AgentCLI.main(Array(CommandLine.arguments.dropFirst()))
exit(status)
