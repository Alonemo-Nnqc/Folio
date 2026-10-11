import Foundation
import FolioTranslate

// `folio-apple-translate --from en --to zh` — pdf2zh_next `--clitranslator` backend
// using Apple's offline Translation framework. See `AppleSystemTranslator`.
let status = await AppleSystemTranslator.runCommandLine(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
