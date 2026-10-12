import FolioCore
import Foundation
import Testing
@testable import FolioCitation

@Suite struct ReferenceFormatTests {
    let bib = #"""
    @comment{exported by someone}
    @article{zhou2018unet,
      title = {{UNet++}: A Nested {U-Net} Architecture for Medical Image Segmentation},
      author = {Zhou, Zongwei and Siddiquee, Md Mahfuzur Rahman and Tajbakhsh, Nima and Jianming Liang},
      journal = "Deep Learning in Medical Image Analysis",
      year = 2018,
      volume = {11045},
      pages = {3--11},
      doi = {10.1007/978-3-030-00889-5_1},
      keywords = {segmentation, medical imaging}
    }
    @inproceedings(tan2021night,
      title = {Night-Time Scene Parsing with a Large Real Dataset},
      author = {Tan, Xin and Xu, Ke and M{\"u}ller, Jan},
      booktitle = {CVPR},
      year = {2021}
    )
    @misc{zhang2026spectral,
      title = {Spectral Dynamic Attention Network},
      author = {Zhang, Tengya},
      eprint = {2604.27326},
      archivePrefix = {arXiv},
      year = {2026}
    }
    """#

    @Test func parsesBibTeX() throws {
        let records = ReferenceReader.parse(bib)
        #expect(records.count == 3)
        let unet = try #require(records.first)
        #expect(unet.citationKey == "zhou2018unet")
        #expect(unet.metadata.title == "UNet++: A Nested U-Net Architecture for Medical Image Segmentation")
        #expect(unet.metadata.authors.map(\.family) == ["Zhou", "Siddiquee", "Tajbakhsh", "Liang"])
        #expect(unet.metadata.year == 2018)
        #expect(unet.metadata.pages == "3-11")
        #expect(unet.metadata.source == "Deep Learning in Medical Image Analysis")
        #expect(unet.keywords == ["segmentation", "medical imaging"])
        #expect(records[1].metadata.type == .conferencePaper)
        #expect(records[1].metadata.authors.last?.family == "Müller")
        #expect(records[2].metadata.type == .preprint)
        #expect(records[2].metadata.arxivId == "2604.27326")
    }

    @Test func risRoundTrip() throws {
        var m = Metadata(title: "Serp-Mamba: Advancing High-Resolution Retinal Vessel Segmentation")
        m.type = .journalArticle
        m.authors = [Author(family: "Wang", given: "Hongqiu"), Author(family: "Chen", given: "Yixian")]
        m.year = 2025
        m.source = "IEEE Transactions on Medical Imaging"
        m.pages = "120-131"
        m.doi = "10.1109/tmi.2025.1"
        let ris = ReferenceFormat.ris.render([CitationEntry(id: "1", citationKey: "wang2025", metadata: m)])
        #expect(ris.contains("TY  - JOUR"))
        #expect(ris.contains("SP  - 120\nEP  - 131"))
        let back = try #require(ReferenceReader.parse(ris).first)
        #expect(back.metadata.title == m.title)
        #expect(back.metadata.authors == m.authors)
        #expect(back.metadata.pages == "120-131")
        #expect(back.metadata.doi == m.doi)
        #expect(back.citationKey == "wang2025")
    }

    @Test func cslJSONRoundTrip() throws {
        var m = Metadata(title: "Mamba as a Bridge")
        m.type = .conferencePaper
        m.authors = [Author(family: "Zhang", given: "Xin")]
        m.year = 2025
        let json = ReferenceFormat.csljson.render([CitationEntry(id: "1", citationKey: "zhang2025", metadata: m)])
        #expect(ReferenceFormat.detect(json) == .csljson)
        let back = try #require(ReferenceReader.parse(json).first)
        #expect(back.metadata.type == .conferencePaper)
        #expect(back.metadata.year == 2025)
        #expect(back.metadata.authors.first?.given == "Xin")
    }

    @Test func detectsFormatsAndIgnoresJunk() {
        #expect(ReferenceFormat.detect(bib) == .bibtex)
        #expect(ReferenceFormat.detect("TY  - JOUR\nTI  - x\nER  - ") == .ris)
        #expect(ReferenceReader.parse("just some text").isEmpty)
        #expect(ReferenceReader.parse("@article{nokey, author = {A}}").isEmpty, "entries without a title are skipped")
    }
}
