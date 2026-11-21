import Foundation
import Testing
@testable import FolioCore

/// #19: fields by type, kept through type changes and saved with the item.
@Suite struct ItemFieldTests {
    @Test func eachTypeShowsItsFieldsNamedForIt() {
        #expect(ItemField.fields(for: .thesis).starts(with: [.source, .place, .genre]))
        #expect(ItemField.source.label(for: .thesis) == String(localized: "授予单位", bundle: .module))
        #expect(ItemField.fields(for: .book).contains(.translators) && !ItemField.fields(for: .book).contains(.source))
        #expect(!ItemField.fields(for: .journalArticle).contains(.place))
    }

    @Test func changingTheTypeHidesNothingThatHasAValue() {
        var m = Metadata(title: "A book")
        m.type = .book
        m.place = "Berlin"
        m.source = "Old venue"
        m.type = .journalArticle
        let shown = ItemField.shown(for: m)
        #expect(shown.contains(.place) && shown.contains(.source))
    }

    @Test func peopleAreTypedOnOneLine() {
        #expect(AuthorFormatter.people("Jähne, Bernd; 王小明、Tengya Zhang") == [
            Author(family: "Jähne", given: "Bernd"), Author(family: "王小明"), Author(family: "Zhang", given: "Tengya"),
        ])
        #expect(AuthorFormatter.joined([Author(family: "Jähne", given: "Bernd"), Author(family: "王小明")]) == "Jähne, Bernd; 王小明")
        var m = Metadata(title: "x")
        ItemField.editors.set("Li, Wei; Chen, Jie", in: &m)
        #expect(m.editors.count == 2)
        ItemField.editors.set("", in: &m)
        #expect(m.editors.isEmpty)
    }

    @Test func theFieldsAreSavedWithTheItem() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Principles of Optics")
        try lib.updateItem(id) { item in
            item.type = .book
            item.place = "Cambridge"
            item.edition = "7th"
            item.editors = [Author(family: "Wolf", given: "Emil")]
            item.translators = [Author(family: "杨葭荪")]
            item.series = "Cambridge Classics"
            item.genre = nil
        }
        let item = try #require(try lib.item(id))
        #expect(item.place == "Cambridge" && item.edition == "7th" && item.series == "Cambridge Classics")
        #expect(item.editors == [Author(family: "Wolf", given: "Emil")] && item.translators == [Author(family: "杨葭荪")])
        #expect(item.metadata.editors == item.editors)
    }
}
