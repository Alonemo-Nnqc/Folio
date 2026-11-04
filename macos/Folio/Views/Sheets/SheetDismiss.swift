import SwiftUI

/// Closes the sheet a SwiftUI view is shown in. Sheets are presented by AppKit window controllers
/// (`presentAsSheet`), where SwiftUI's own `dismiss` action has nothing to dismiss.
struct SheetDismissAction {
    var handler: () -> Void = {}
    func callAsFunction() { handler() }
}

extension EnvironmentValues {
    @Entry var sheetDismiss = SheetDismissAction()
}
