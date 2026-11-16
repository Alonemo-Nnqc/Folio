import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

/// Folio's glossary: terms kept from paper to paper, the user's word over a model's.
@Suite struct GlossaryStoreTests {
    @Test func whatTheUserWroteStaysWhateverAModelFindsLater() {
        let folder = TemporaryDirectory()
        let store = GlossaryStore(url: folder.url.appending(path: "glossary.json"))
        let mine = store.save(GlossaryTerm(source: "domain generalization", target: "域泛化", language: "zh"))
        #expect(mine != nil)
        // A model finds the same term (written a little differently) and a new one.
        let added = store.learn([GlossaryEntry(source: "Domain Generalization", target: "领域泛化"), GlossaryEntry(source: "style transfer", target: "风格迁移"),
                                 GlossaryEntry(source: "CLIP", target: "CLIP")], language: "zh-CN", paper: "A Paper")
        #expect(added == 1, "the term already there is left alone; a name kept as it is is no term")
        let terms = store.terms(language: "zh")
        #expect(terms.map(\.target) == ["域泛化", "风格迁移"])
        #expect(terms[1].origin == .extracted && terms[1].paper == "A Paper")
        // Read again from disk by another store.
        #expect(GlossaryStore(url: folder.url.appending(path: "glossary.json")).terms().count == 2)
    }

    @Test func termsAreChangedSwitchedOffAndRemoved() throws {
        let folder = TemporaryDirectory()
        let store = GlossaryStore(url: folder.url.appending(path: "glossary.json"))
        store.learn([GlossaryEntry(source: "backbone", target: "主干"), GlossaryEntry(source: "ablation", target: "消融")], language: "zh", paper: nil)
        var term = try #require(store.terms().first { $0.source == "backbone" })
        term.target = "骨干网络"
        store.save(term)
        #expect(store.entries(for: "zh").first { $0.source == "backbone" }?.target == "骨干网络")
        #expect(store.terms().count == 2, "changed in place, not added again")
        var other = try #require(store.terms().first { $0.source == "ablation" })
        other.isEnabled = false
        store.save(other)
        #expect(store.entries(for: "zh").map(\.source) == ["backbone"], "a term switched off stays in the list but is not used")
        store.remove([term.id])
        #expect(store.terms().map(\.source) == ["ablation"])
        // Another language has its own terms.
        store.save(GlossaryTerm(source: "backbone", target: "バックボーン", language: "ja"))
        #expect(store.entries(for: "ja").count == 1 && store.entries(for: "zh").isEmpty)
        #expect(store.save(GlossaryTerm(source: "  ", target: "x", language: "zh")) == nil)
    }

    @Test func aListGoesOutAndComesBackAsCSV() throws {
        let folder = TemporaryDirectory()
        let store = GlossaryStore(url: folder.url.appending(path: "a.json"))
        store.save(GlossaryTerm(source: "few-shot learning", target: "小样本学习", language: "zh"))
        store.save(GlossaryTerm(source: "loss", target: "损失", language: "zh"))
        // A comma and a quote in a term come back as they went out.
        store.save(GlossaryTerm(source: "precision, recall", target: "精确率、召回率", language: "zh"))
        store.save(GlossaryTerm(source: "the \"bitter lesson\"", target: "“苦涩的教训”", language: "zh"))
        let file = folder.url.appending(path: "terms.csv")
        try store.exportCSV(language: "zh").write(to: file, atomically: true, encoding: .utf8)
        let other = GlossaryStore(url: folder.url.appending(path: "b.json"))
        #expect(other.importCSV(file, language: "zh") == 4)
        #expect(other.entries(for: "zh") == store.entries(for: "zh"))
        #expect(other.terms().allSatisfy { $0.origin == .user })
    }
}

@Suite(.serialized) struct GlossaryJobTests {
    @Test func termsOfEarlierPapersAreUsedAndNewOnesKept() async throws {
        let folder = TemporaryDirectory()
        let support = folder.url.appending(path: "support")
        // A term from an earlier paper, changed by the user.
        let store = GlossaryStore(url: support.appending(path: "glossary.json"))
        store.save(GlossaryTerm(source: "domain", target: "领域", language: "zh"))
        let input = folder.url.appending(path: "paper.pdf")
        try ServiceJobTests.paper(paragraphs: 3).write(to: input)
        let service = try await LocalService.start { _, body in
            let (system, texts) = LocalService.parts(body)
            if system.hasPrefix("You build glossaries") {
                return LocalService.chat(#"{"terms": [{"source": "domain", "target": "域"}, {"source": "feature", "target": "特征"}]}"#)
            }
            return LocalService.chat(LocalService.json(texts.mapValues { _ in "这是译文。" }))
        }
        func run(_ options: TranslationOptions, out: String) async -> [TranslationEvent] {
            let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: out), serviceID: "openaicompatible",
                                             fieldValues: ["--openai-compatible-base-url": service.base, "--openai-compatible-model": "m"], options: options)
            return await collect(TranslationJob(request: request, supportDirectory: support).start())
        }
        var options = TranslationOptions(outputs: .mono, ignoreCache: true)
        guard case .finished = await run(options, out: "out").last else { Issue.record("did not finish"); return }
        let prompts = service.requests.map { LocalService.parts($0).system }.filter { !$0.hasPrefix("You build glossaries") }
        #expect(prompts.allSatisfy { $0.contains("domain → 领域") }, "every batch has the kept term, the first ones too")
        #expect(!prompts.contains { $0.contains("domain → 域\n") || $0.hasSuffix("domain → 域") }, "the user's translation wins over the model's")
        // What the model found is kept for the next paper; what was there is as it was.
        let kept = GlossaryStore(url: support.appending(path: "glossary.json")).terms(language: "zh")
        #expect(kept.map(\.source) == ["domain", "feature"] && kept[0].target == "领域" && kept[1].origin == .extracted)
        // With the option off, nothing more is kept.
        GlossaryStore(url: support.appending(path: "glossary.json")).remove([kept[1].id])
        options.rememberTerms = false
        guard case .finished = await run(options, out: "out2").last else { Issue.record("did not finish"); return }
        #expect(GlossaryStore(url: support.appending(path: "glossary.json")).terms().map(\.source) == ["domain"])
    }
}
