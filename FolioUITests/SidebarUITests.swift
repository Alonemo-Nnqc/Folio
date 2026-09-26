import FolioCore
import XCTest

final class SidebarUITests: FolioUITestCase {
    override func seed() throws {
        let group = try library.createGroup(name: "夜间场景")
        try addItem("Night-Time Scene Parsing With a Large Real Dataset", group: group.id)
        try addItem("UNet++: A Nested U-Net Architecture")
    }

    /// SIDE-03/04/13: built-in groups with counts.
    func testBuiltInGroupsShowCounts() throws {
        launch()
        waitFor(sidebarRow("所有文献"))
        XCTAssertTrue(sidebarRow("未分组").exists)
        XCTAssertTrue(sidebarRow("回收站").exists)
        XCTAssertTrue(sidebarRow("所有文献").staticTexts["2"].exists, "所有文献 shows 2")
        sidebarRow("未分组").click()
        waitFor(itemRow("UNet++"))
        XCTAssertFalse(itemRow("Night-Time").exists, "filed item is not in 未分组")
    }

    /// SIDE-08, SIDE-06: create, rename inline; subgroups have no "新建子分组".
    func testCreateRenameAndSubgroupMenu() throws {
        launch()
        app.buttons["newGroupButton"].click()
        let editor = sidebar.textFields.firstMatch
        waitFor(editor)
        replaceText(in: editor, with: "论文辅导")
        waitFor(sidebarRow("论文辅导"))
        XCTAssertNotNil(try library.snapshot().groupsById.values.first { $0.name == "论文辅导" })

        sidebarRow("论文辅导").rightClick()
        waitFor(menuItem("新建子分组"))
        XCTAssertTrue(menuItem("重命名").exists)
        XCTAssertTrue(menuItem("删除分组").exists)
        menuItem("新建子分组").click()
        let childEditor = sidebar.textFields.firstMatch
        waitFor(childEditor)
        replaceText(in: childEditor, with: "2026美赛")
        waitFor(sidebarRow("2026美赛"))

        sidebarRow("2026美赛").rightClick()
        waitFor(menuItem("重命名"))
        XCTAssertFalse(menuItem("新建子分组").exists, "two levels at most")
        app.typeKey(.escape, modifierFlags: [])

        let snapshot = try library.snapshot()
        let parent = try XCTUnwrap(snapshot.groupsById.values.first { $0.name == "论文辅导" })
        let child = try XCTUnwrap(snapshot.groupsById.values.first { $0.name == "2026美赛" })
        XCTAssertEqual(child.parentId, parent.id)
    }

    /// SIDE-09: deleting a group asks first and keeps its items by default.
    func testDeleteGroupConfirmsAndKeepsItems() throws {
        launch()
        sidebarRow("夜间场景").rightClick()
        menuItem("删除分组").click()
        let sheet = app.sheets.firstMatch
        waitFor(sheet)
        XCTAssertTrue(sheet.buttons["同时将条目移到回收站"].exists)
        sheet.buttons["删除分组"].click()
        waitUntilGone(sidebarRow("夜间场景"))
        sidebarRow("未分组").click()
        waitFor(itemRow("Night-Time"))
    }

    /// TRASH-06 and SIDE-07: context menus of 回收站 and of the blank sidebar area.
    func testTrashAndBlankAreaMenus() throws {
        launch()
        sidebarRow("回收站").rightClick()
        waitFor(menuItem("清空回收站"))
        app.typeKey(.escape, modifierFlags: [])

        let blank = sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        blank.rightClick()
        waitFor(menuItem("创建分组"))
        XCTAssertTrue(menuItem("搜索文献").exists)
        menuItem("搜索文献").click()
        waitFor(app.searchFields["sidebarSearchField"])
    }

    /// SEARCH-01/02/03: the sidebar search filters the list; scope can widen to the whole library.
    func testSearchFiltersList() throws {
        launch()
        app.buttons["searchButton"].click()
        let field = app.searchFields["sidebarSearchField"]
        waitFor(field)
        field.typeText("unet nested")
        waitFor(itemRow("UNet++"))
        waitUntilGone(itemRow("Night-Time"))

        sidebarRow("夜间场景").click()
        waitUntilGone(itemRow("UNet++"))
        app.radioButtons["全部文献"].click()
        waitFor(itemRow("UNet++"))
    }
}
