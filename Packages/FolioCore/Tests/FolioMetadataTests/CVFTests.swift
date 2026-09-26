import FolioCore
import Foundation
import Testing
@testable import FolioMetadata

@Suite struct CVFTests {
    static let watermark = """
    This CVPR paper is the Open Access version, provided by the Computer Vision Foundation.
    Except for this watermark, it is identical to the accepted version;
    the final published version of the proceedings is available on IEEE Xplore.
    Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation
    Kai Zhu1,2 Li Chen1,2, Jun Cheng3
    1School of Computer Science and Technology, Wuhan University of Science and Technology
    """

    static func facts(fileName: String = "CVPR2026_Dual_level_Adapter.pdf", embeddedAuthor: String? = "Kai Zhu; Li Chen; Jun Cheng") -> PDFFacts {
        PDFFacts(fileName: fileName,
                 embeddedTitle: "Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation",
                 embeddedAuthor: embeddedAuthor,
                 metadataText: "IEEE Conference on Computer Vision and Pattern Recognition",
                 firstPageText: watermark,
                 firstPageLines: watermark.split(separator: "\n").map { TextLine(text: String($0), fontSize: 10, fontName: "Times") })
    }

    @Test func slugsFollowCVFRules() {
        // Real titles and paths from openaccess.thecvf.com/CVPR2026.
        let cases: [(String, String, String)] = [
            ("Yang", "DirectFisheye-GS: Enabling Native Fisheye Input in Gaussian Splatting with Cross-View Joint Optimization",
             "Yang_DirectFisheye-GS_Enabling_Native_Fisheye_Input_in_Gaussian_Splatting_with_Cross-View_CVPR_2026_paper.html"),
            ("Han", "Unique Lives, Shared World: Learning from Single-Life Videos",
             "Han_Unique_Lives_Shared_World_Learning_from_Single-Life_Videos_CVPR_2026_paper.html"),
            ("Maruani", "Illustrator's Depth: Monocular Layer Index Prediction for Image Decomposition",
             "Maruani_Illustrators_Depth_Monocular_Layer_Index_Prediction_for_Image_Decomposition_CVPR_2026_paper.html"),
            ("Chowers", "Is the Modality Gap a Bug or a Feature? A Robustness Perspective",
             "Chowers_Is_the_Modality_Gap_a_Bug_or_a_Feature_A_CVPR_2026_paper.html"),
        ]
        for (family, title, file) in cases {
            #expect(CVFClient.url(conference: "CVPR", year: 2026, family: family, title: title)?.absoluteString
                    == "https://openaccess.thecvf.com/content/CVPR2026/html/\(file)")
        }
        #expect(CVFClient.url(conference: "CVPR", year: 2020, family: "He", title: "Momentum Contrast")?.absoluteString
                == "https://openaccess.thecvf.com/content_CVPR_2020/html/He_Momentum_Contrast_CVPR_2020_paper.html")
    }

    @Test func parsesPaperPage() throws {
        let html = String(decoding: try Fixtures.data("cvf_paper.html"), as: UTF8.self)
        let url = URL(string: "https://openaccess.thecvf.com/content/CVPR2026/html/Zhu_x.html")!
        let m = try #require(CVFClient.parse(html, url: url))
        #expect(m.title == "Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation")
        #expect(m.authors == [Author(family: "Zhu", given: "Kai"), Author(family: "Chen", given: "Li"), Author(family: "Cheng", given: "Jun")])
        #expect(m.year == 2026)
        #expect(m.pages == "36300-36310")
        #expect(m.type == .conferencePaper)
        #expect(m.source == "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)")
        #expect(m.abstract?.hasPrefix("Curvilinear structure segmentation is essential") == true)
        #expect(m.url == url.absoluteString)
    }

    @Test func detectsWatermarkYearAndFirstAuthor() throws {
        let lookup = try #require(CVFLookup.detect(Self.facts(), guesses: ["Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation"],
                                                   currentYear: 2026))
        #expect(lookup.conference == "CVPR")
        #expect(lookup.years == [2026], "year from the file name")
        #expect(lookup.familyName == "Zhu")
        #expect(lookup.fallback?.authors.count == 3)
        #expect(lookup.fallback?.year == 2026)
    }

    @Test func firstAuthorComesFromThePageWhenMetadataHasNone() throws {
        let lookup = try #require(CVFLookup.detect(Self.facts(fileName: "paper.pdf", embeddedAuthor: nil),
                                                   guesses: ["Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation"],
                                                   currentYear: 2026))
        #expect(lookup.familyName == "Zhu")
        #expect(lookup.years == [2026, 2025, 2024], "no explicit year: try recent ones")
        #expect(lookup.fallback == nil, "no embedded authors to trust")
    }

    @Test func nonCVFPDFsAreIgnored() {
        let facts = PDFFacts(fileName: "x.pdf", firstPageText: "Some Journal Article\nJane Doe")
        #expect(CVFLookup.detect(facts, guesses: ["Some Journal Article"]) == nil)
    }

    @Test func engineResolvesCVFPaperWhenNoOtherSourceHasIt() async throws {
        let html = try Fixtures.data("cvf_paper.html")
        // Title first (the generated PDF draws line 1 large), author line right under it, watermark below.
        let pdf = try Fixtures.pdf(lines: ["Dual-level Adapter Boosting Prompt-free",
                                           "Curvilinear Structure Segmentation",
                                           "Kai Zhu1,2 Li Chen1,2, Jun Cheng3",
                                           "This CVPR paper is the Open Access version, provided by the Computer Vision Foundation.",
                                           "Except for this watermark, it is identical to the accepted version;"], titleLines: 2)
        let engine = MetadataEngine.testing { url in
            url.host() == "openaccess.thecvf.com" && url.path.hasSuffix("Zhu_Dual-level_Adapter_Boosting_Prompt-free_Curvilinear_Structure_Segmentation_CVPR_2026_paper.html")
                ? (html, 200) : (Data(), 404)
        }
        // The generated PDF has no metadata, so the year comes from the recent-years guess (2026 included).
        guard case .found(let m) = await engine.resolve(pdfAt: pdf) else { Issue.record("expected a match"); return }
        #expect(m.pages == "36300-36310")
        #expect(m.type == .conferencePaper)
    }
}
