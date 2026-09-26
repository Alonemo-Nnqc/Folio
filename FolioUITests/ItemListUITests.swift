import FolioCore
import XCTest

final class ItemListUITests: FolioUITestCase {
    var multiFileItem: String!
    var groupId: String!

    override func seed() throws {
        groupId = try library.createGroup(name: "DG-Night").id
        multiFileItem = try addItem("Spectral Dynamic Attention Network", extraFiles: 1)
        try addItem("Serp-Mamba: Advancing High-Resolution Retinal Vessel Segmentation", family: "Wang", year: 2024,
                    source: "IEEE Transactions on Medical Imaging")
    }

    private func expand(_ row: XCUIElement) {
        row.disclosureTriangles.firstMatch.click()
    }

    /// LIST-03, FILE-01/02/03: expanding shows the files; the first file carries the 默认 badge.
    func testExpandShowsFilesWithDefaultBadge() throws {
        launch()
        let row = itemRow("Spectral Dynamic")
        waitFor(row)
        XCTAssertEqual(row.disclosureTriangles.firstMatch.value as? Int, 0, "collapsed arrow points right")
        expand(row)
        waitFor(itemList.cells.matching(NSPredicate(format: "label CONTAINS '（默认）'")).firstMatch)
        XCTAssertEqual(itemList.cells.matching(NSPredicate(format: "label CONTAINS '（默认）'")).count, 1)
        XCTAssertTrue(itemList.cells.matching(NSPredicate(format: "label BEGINSWITH 'supplement-0'")).firstMatch.exists)
    }

    /// FILE-04: right-clicking a file makes it the default; the badge moves.
    func testSetDefaultFileFromContextMenu() throws {
        launch()
        expand(itemRow("Spectral Dynamic"))
        let supplement = itemList.cells.matching(NSPredicate(format: "label BEGINSWITH 'supplement-0'")).firstMatch
        waitFor(supplement)
        supplement.rightClick()
        menuItem("设为默认打开文件").click()
        waitFor(itemList.cells.matching(NSPredicate(format: "label BEGINSWITH 'supplement-0' AND label CONTAINS '（默认）'")).firstMatch)
        let files = try library.files(ofItem: multiFileItem)
        XCTAssertEqual(try library.item(multiFileItem)?.defaultFileId, files.first { $0.originalName.hasPrefix("supplement-0") }?.id)
    }

    /// LIST-08, OPEN-03: double-click opens the default file and marks the item as being read.
    func testDoubleClickOpensDefaultFile() throws {
        launch()
        let row = itemRow("Serp-Mamba")
        waitFor(row)
        row.cells.firstMatch.doubleClick()
        let deadline = Date().addingTimeInterval(5)
        while openedPaths().isEmpty && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(openedPaths().count, 1)
        XCTAssertTrue(openedPaths().first?.contains("Wang_2024_Serp-Mamba") ?? false, "\(openedPaths())")
        let item = try XCTUnwrap(library.snapshot().items.values.first { $0.title.hasPrefix("Serp-Mamba") })
        XCTAssertEqual(item.readStatus, .reading)
    }

    /// LIST-02: the header menu hides and shows columns.
    func testHeaderMenuTogglesColumns() throws {
        launch()
        let header = itemList.buttons["来源"]
        waitFor(header)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        menuItem("来源").click()
        waitUntilGone(itemList.buttons["来源"])
        itemList.buttons["标题"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        menuItem("DOI").click()
        waitFor(itemList.buttons["DOI"])
    }

    /// LIST-12, DUP-05, TRASH-02: 添加到 a group, "already there" notice, remove from the group.
    func testAddToGroupAndRemoveFromGroup() throws {
        launch()
        let row = itemRow("Serp-Mamba")
        waitFor(row)
        row.rightClick()
        menuItem("添加到").hover()
        menuItem("DG-Night").click()
        waitFor(app.staticTexts["已添加到「DG-Night」"])

        row.rightClick()
        menuItem("添加到").hover()
        menuItem("DG-Night").click()
        waitFor(app.staticTexts["「DG-Night」中已有该条目"])

        sidebarRow("DG-Night").click()
        let inGroup = itemRow("Serp-Mamba")
        waitFor(inGroup)
        inGroup.rightClick()
        XCTAssertFalse(menuItem("DG-Night").exists, "current group is not offered")
        menuItem("从当前分组移除").click()
        waitUntilGone(itemRow("Serp-Mamba"))
        XCTAssertEqual(try library.rowsIn(.trash).count, 0, "removing from a group does not trash")
    }

    /// TRASH-01/04/05: delete → trash → restore → back in its group.
    func testDeleteRestoreRoundTrip() throws {
        _ = try library.addItems([multiFileItem], toGroup: groupId, includeSubgroups: true)
        launch()
        let row = itemRow("Spectral Dynamic")
        waitFor(row)
        row.rightClick()
        menuItem("删除").click()
        waitUntilGone(itemRow("Spectral Dynamic"))

        sidebarRow("回收站").click()
        let trashed = itemRow("Spectral Dynamic")
        waitFor(trashed)
        trashed.rightClick()
        XCTAssertTrue(menuItem("彻底删除").exists)
        menuItem("恢复").click()
        waitUntilGone(itemRow("Spectral Dynamic"))
        sidebarRow("DG-Night").click()
        waitFor(itemRow("Spectral Dynamic"))
    }

    // Drags (DND-03/04, SIDE-12, TRASH-10) are covered by script/drag-tests.sh: XCUITest's synthesized
    // drags are not recognised by NSOutlineView, real mouse events are.
}

extension Library {
    func rowsIn(_ scope: ViewScope) throws -> [String] {
        let s = try snapshot()
        return ViewResolver.rows(ViewQuery(scope: scope, sort: s.sort(for: scope)), in: s)
    }
}
