import FolioCore
import FolioTranslate
import Foundation

/// Folio's settings as a part of a package (`folio-settings.json`): what both platforms know, under the same keys, and what
/// only means something on the platform it was written on. API keys are only in it locked with a password.
nonisolated struct SettingsPackage {
    private enum Kind { case bool, number, string, strings, table, tables }

    /// Settings that mean the same on macOS and Windows.
    private static let shared: [String: Kind] = [
        "includeSubgroupItems": .bool, "autoRenameFiles": .bool, "autoPurgeTrash": .bool, "crossrefMailto": .string,
        "readerZoom": .string, "readerLayout": .string, "reopenReaderTabs": .bool, "highlightColor": .string,
        "annotationToolColors": .table, "annotationCustomColors": .strings, "inkLineWidth": .number, "textBoxFontSize": .number,
        "returnToSelectAfterPlacing": .bool, "rememberReadingPosition": .bool, "showAnnotationTooltips": .bool, "readerEraserSize": .string,
        "useZoteroRecognizer": .bool, "translationService": .string, "translationFields": .tables, "selectedTranslationProfiles": .table,
        "appearance": .string, "markReadingOnOpen": .bool, "readerPageShadows": .bool, "annotationAuthor": .string,
        "autoRetrieveOnImport": .bool, "aiAllowWrites": .bool, "browserConnectorEnabled": .bool,
        "selectionTranslationEnabled": .bool, "selectionTranslationTrigger": .string, "selectionTranslationService": .string,
        "selectionTranslationFallback": .bool, "backgroundTranslucency": .number, "translationParallelJobs": .number,
        "translationParallelTotal": .number, "autoTranslateImports": .bool, "journalMetricsAutoFetch": .bool, "showTranslatedBadge": .bool,
        "inspectorFloating": .bool, "showReadingRings": .bool, "offerMarkAsRead": .bool, "markdownToolbar": .bool,
        "markdownFontSize": .number, "markdownPanelFontSize": .number, "markdownTypeface": .string, "markdownLineHeight": .number, "markdownParagraphSpacing": .number,
        "markdownHeadingScale": .number, "markdownCodeScale": .number, "markdownReadableWidth": .number, "markdownCodeIndent": .number,
        "markdownShowsHandles": .bool, "markdownShowsPlaceholders": .bool, "markdownShowsWordCount": .bool, "markdownHighlightsCode": .bool, "markdownStrikesDone": .bool,
        "markdownChecksSpelling": .bool, "markdownSlashMenu": .bool, "markdownContinuesLists": .bool, "markdownCompletesSymbols": .bool, "markdownPastesLinks": .bool,
    ]
    /// This Mac's own: kept as they are, for another Mac.
    private static let platformKeys = ["openWithMode", "openWithAppPath", "selectionTranslationShortcut", "exportFormat"]
    private static let platformPrefixes = ["NSToolbar Configuration", "NSTableView"]
    private static let openAlex = "openAlexAPIKey"
    private static let easyScholar = (service: "easyscholar", option: "secretKey")

    /// Where settings are read from and written to.
    struct Stores {
        var defaults: UserDefaults
        /// The app's own preferences (what is stored in them, without defaults).
        var domain: String
        var translation: any SecretStoring
        var journals: any SecretStoring
        var glossary: GlossaryStore
    }

    // MARK: Writing

    /// `password`: API keys go along, locked with it (nil: without them).
    static func data(from stores: Stores, password: String?) throws -> Data {
        var values: [String: Any] = [:]
        for (key, kind) in shared {
            if let value = stores.defaults.object(forKey: key), fits(value, kind) { values[key] = value }
        }
        let profiles = stores.defaults.data(forKey: "translationProfiles").flatMap { try? JSONDecoder().decode([TranslationProfile].self, from: $0) } ?? []
        if let data = stores.defaults.data(forKey: "translationOptions"), var options = try? JSONDecoder().decode(TranslationOptions.self, from: data) {
            // A file of this computer, pages of one paper.
            options.glossaryFile = nil
            options.pages = nil
            values["translationOptions"] = try json(options)
        }
        values["translationProfiles"] = try json(profiles)
        let stored = stores.defaults.persistentDomain(forName: stores.domain) ?? [:]
        values["language"] = (stored["AppleLanguages"] as? [String])?.first ?? ""
        let own = stored.filter { key, _ in platformKeys.contains(key) || platformPrefixes.contains { key.hasPrefix($0) } }
        var object: [String: Any] = ["platform": "macos", "values": values,
                                     "plist": try PropertyListSerialization.data(fromPropertyList: own, format: .binary, options: 0).base64EncodedString()]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        object["glossary"] = try JSONSerialization.jsonObject(with: encoder.encode(stores.glossary.terms()))
        if let password, !password.isEmpty {
            var secrets: [String: String] = [:]
            for (owner, option) in owners(profiles) {
                if let value = try stores.translation.get(serviceID: owner, option: option), !value.isEmpty { secrets[SecretStore.account(serviceID: owner, option: option)] = value }
            }
            if let value = try stores.journals.get(serviceID: easyScholar.service, option: easyScholar.option), !value.isEmpty {
                secrets[SecretStore.account(serviceID: easyScholar.service, option: easyScholar.option)] = value
            }
            if let value = stores.defaults.string(forKey: openAlex), !value.isEmpty { secrets[openAlex] = value }
            object["secrets"] = try json(PasswordBox(JSONEncoder().encode(secrets), password: password))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func json(_ value: some Encodable) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }

    private static func owners(_ profiles: [TranslationProfile]) -> [(String, String)] {
        var result: [(String, String)] = []
        for service in TranslationServiceCatalog.all {
            let names = [service.id] + profiles.filter { $0.serviceID == service.id }.map(\.secretOwner)
            for field in service.secretFields { result += names.map { ($0, field.option) } }
        }
        return result
    }

    private static func fits(_ value: Any, _ kind: Kind) -> Bool {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        return switch kind {
        case .bool: isBool || (value as? NSNumber).map { $0 == 0 || $0 == 1 } ?? false
        case .number: value is NSNumber && !isBool
        case .string: value is String
        case .strings: value is [String]
        case .table: value is [String: String]
        case .tables: value is [String: [String: String]]
        }
    }

    // MARK: Reading

    private let object: [String: Any]
    private let box: PasswordBox?

    init(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["values"] is [String: Any] else { throw ZipError.notAnArchive }
        self.object = object
        box = try object["secrets"].map { try JSONDecoder().decode(PasswordBox.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    /// API keys are in it.
    var hasSecrets: Bool { box != nil }

    /// The API keys; nil: the password is wrong.
    func secrets(password: String) -> [String: String]? {
        box?.open(password: password).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    /// Makes these the settings (the app reads them when it starts). What is only here — translation services set up, terms
    /// of the glossary — stays. `secrets`: the keys, unlocked (nil: those here stay).
    func apply(to stores: Stores, secrets: [String: String]?) throws {
        let values = object["values"] as? [String: Any] ?? [:], defaults = stores.defaults
        /// A key that is here is never sent to another address than it was entered for, unless the package brings its own.
        func keepsKeySafe(_ owner: String, _ serviceID: String, _ here: [String: String]?, _ new: [String: String]) throws -> Bool {
            guard let service = TranslationServiceCatalog.service(id: serviceID) else { return true }
            guard service.fields.contains(where: { $0.kind == .url && (here?[$0.option] ?? "") != (new[$0.option] ?? "") }) else { return true }
            return try service.secretFields.allSatisfy {
                let mine = try stores.translation.get(serviceID: owner, option: $0.option) ?? ""
                return mine.isEmpty || secrets?[SecretStore.account(serviceID: owner, option: $0.option)] != nil
            }
        }
        for (key, kind) in Self.shared {
            // Not changed there: as it comes.
            if values[key] == nil, [.bool, .number, .string].contains(kind) { defaults.removeObject(forKey: key) }
            guard var value = values[key], Self.fits(value, kind) else { continue }
            if kind == .bool { value = (value as? NSNumber)?.boolValue ?? false }
            if kind == .tables, let new = value as? [String: [String: String]] {
                let here = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
                value = here.merging(try new.filter { try keepsKeySafe($0.key, $0.key, here[$0.key], $0.value) }) { $1 }
            }
            if key == "selectedTranslationProfiles", let new = value as? [String: String] {
                value = (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).merging(new) { $1 }
            }
            defaults.set(value, forKey: key)
        }
        func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
            value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        if var options = decode(TranslationOptions.self, values["translationOptions"]) {
            options.glossaryFile = nil
            options.pages = nil
            defaults.set(try JSONEncoder().encode(options), forKey: "translationOptions")
        }
        let profiles = decode([TranslationProfile].self, values["translationProfiles"]) ?? []
        if !profiles.isEmpty {
            let here = defaults.data(forKey: "translationProfiles").flatMap { try? JSONDecoder().decode([TranslationProfile].self, from: $0) } ?? []
            let new = try profiles.filter { profile in try keepsKeySafe(profile.secretOwner, profile.serviceID, here.first { $0.id == profile.id }?.fields, profile.fields) }
            let ids = Set(new.map(\.id))
            defaults.set(try JSONEncoder().encode(here.filter { !ids.contains($0.id) } + new), forKey: "translationProfiles")
        }
        if let language = values["language"] as? String {
            if ["zh-Hans", "en"].contains(language) { defaults.set([language], forKey: "AppleLanguages") } else { defaults.removeObject(forKey: "AppleLanguages") }
        }
        if object["platform"] as? String == "macos", let data = (object["plist"] as? String).flatMap({ Data(base64Encoded: $0) }),
           let own = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in own where Self.platformKeys.contains(key) || Self.platformPrefixes.contains(where: { key.hasPrefix($0) }) {
                defaults.set(value, forKey: key)
            }
        }
        if let glossary = object["glossary"], let data = try? JSONSerialization.data(withJSONObject: glossary) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let terms = try? decoder.decode([GlossaryTerm].self, from: data), !terms.isEmpty { stores.glossary.merge(terms) }
        }
        guard let secrets else { return }
        for (owner, option) in Self.owners(profiles) {
            if let value = secrets[SecretStore.account(serviceID: owner, option: option)] { try stores.translation.set(value, serviceID: owner, option: option) }
        }
        if let value = secrets[SecretStore.account(serviceID: Self.easyScholar.service, option: Self.easyScholar.option)] {
            try stores.journals.set(value, serviceID: Self.easyScholar.service, option: Self.easyScholar.option)
        }
        if let value = secrets[Self.openAlex] { defaults.set(value, forKey: Self.openAlex) }
    }
}
