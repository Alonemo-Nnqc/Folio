import AppKit
import CoreText
import FolioCore
import Foundation
import PDFKit

// Seeds a Folio library for screenshots and performance checks.
//   swift run folio-seed demo <libraryDir> [--pdfs <dir with real PDFs>]
//   swift run folio-seed bulk <libraryDir> <count>

struct Paper {
    var title: String
    var authors: [(String, String)]
    var year: Int
    var source: String
    var type: ItemType = .journalArticle
    var doi: String?
    var abstract: String?
}

let papers: [Paper] = [
    Paper(title: "Spectral Dynamic Attention Network for Hyperspectral Image Super-Resolution",
          authors: [("Zhang", "Tengya"), ("Gao", "Feng"), ("Qi", "Lin"), ("Dong", "Junyu"), ("Du", "Qian")], year: 2026,
          source: "arXiv", type: .preprint, doi: "10.48550/arxiv.2604.27326",
          abstract: "Hyperspectral image super-resolution is essential for enhancing the spatial fidelity of HSI data, yet existing deep learning methods often struggle with substantial spectral redundancy and the limited non-linear modeling capacity of standard feed-forward networks (FFNs). To address these challenges, we propose Spectral Dynamic Attention Network."),
    Paper(title: "UNet++: A Nested U-Net Architecture for Medical Image Segmentation",
          authors: [("Zhou", "Zongwei"), ("Siddiquee", "Md Mahfuzur Rahman"), ("Tajbakhsh", "Nima"), ("Liang", "Jianming")],
          year: 2018, source: "arXiv", type: .preprint, doi: "10.48550/arxiv.1807.10165"),
    Paper(title: "Night-Time Scene Parsing With a Large Real Dataset", authors: [("Tan", "Xin"), ("Xu", "Ke"), ("Cao", "Ying")],
          year: 2021, source: "IEEE Transactions on Image Processing", doi: "10.1109/tip.2021.3122004"),
    Paper(title: "Serp-Mamba: Advancing High-Resolution Retinal Vessel Segmentation With Selective State-Space Model",
          authors: [("Wang", "Hongqiu"), ("Chen", "Yixian")], year: 2025, source: "IEEE Transactions on Medical Imaging"),
    Paper(title: "Semantic Nighttime Image Segmentation With Synthetic Stylized Data, Gated Convolution, and Auxiliary Loss",
          authors: [("Peng", "Junhan"), ("Li", "Wei"), ("Wu", "Zhen")], year: 2021, source: "2021 IEEE International Conference on Image Processing",
          type: .conferencePaper),
    Paper(title: "Multimodal self-supervised retinal vessel segmentation", authors: [("Yin", "Pengshuai"), ("Liu", "Hao")],
          year: 2026, source: "Neural Networks"),
    Paper(title: "RVS-FDSC: A retinal vessel segmentation method with four-directional strip convolution to enhance feature extraction",
          authors: [("Kong", "Linfeng"), ("Wu", "Yun")], year: 2024, source: "Biomedical Signal Processing and Control",
          doi: "10.1016/j.bspc.2024.106296"),
    Paper(title: "Stronger, Fewer, & Superior: Harnessing Vision Foundation Models for Domain Generalized Semantic Segmentation",
          authors: [("Wei", "Zhixiang"), ("Chen", "Lin"), ("Jin", "Yi")], year: 2024, source: "arXiv", type: .preprint),
    Paper(title: "SCSA: Exploring the Synergistic Effects Between Spatial and Channel Attention",
          authors: [("Si", "Yunzhong"), ("Xu", "Huiying")], year: 2024, source: "arXiv", type: .preprint),
    Paper(title: "Mamba as a Bridge: Where Vision Foundation Models Meet Vision Language Models for Domain-Generalized Semantic Segmentation",
          authors: [("Zhang", "Xin"), ("Tan", "Robby T")], year: 2025, source: "CVPR", type: .conferencePaper),
    Paper(title: "OverLoCK: An Overview-first-Look-Closely-next ConvNet with Context-Mixing Dynamic Kernels",
          authors: [("Lou", "Meng"), ("Yu", "Yizhou")], year: 2025, source: "arXiv", type: .preprint),
    Paper(title: "SDSFusion: A Semantic-Aware Infrared and Visible Image Fusion Network for Degraded Scenes",
          authors: [("Chen", "Jun"), ("Yang", "Liling")], year: 2025, source: "IEEE Transactions on Image Processing"),
]

func makePDF(at url: URL, lines: [String]) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
    context.beginPDFPage(nil)
    var y: CGFloat = 740
    for (index, line) in lines.enumerated() {
        let font = CTFontCreateWithName("Helvetica" as CFString, index == 0 ? 16 : 10, nil)
        context.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
        y -= index == 0 ? 26 : 14
    }
    context.endPDFPage()
    context.closePDF()
}

/// Adds a yellow highlight and a note so the 标注 tab has something to show.
func annotate(_ url: URL) {
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return }
    let bounds = page.bounds(for: .mediaBox)
    if let selection = page.selection(for: CGRect(x: 30, y: bounds.height - 90, width: bounds.width - 60, height: 50)) {
        let highlight = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
        highlight.color = NSColor.systemYellow.withAlphaComponent(0.5)
        highlight.contents = "核心贡献：动态光谱注意力"
        page.addAnnotation(highlight)
    }
    let note = PDFAnnotation(bounds: CGRect(x: 40, y: 400, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "对比实验可以复现 Table 2"
    page.addAnnotation(note)
    document.write(to: url)
}

func metadata(for paper: Paper) -> Metadata {
    var m = Metadata(title: paper.title)
    m.authors = paper.authors.map { Author(family: $0.0, given: $0.1) }
    m.year = paper.year
    m.source = paper.source
    m.type = paper.type
    m.doi = paper.doi
    m.abstract = paper.abstract
    return m
}

func demo(root: URL, realPDFs: URL?) throws {
    let library = try Library(root: root)
    let work = FileManager.default.temporaryDirectory.appending(path: "folio-seed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let real = realPDFs.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }?
        .filter { $0.pathExtension == "pdf" }.sorted { $0.path < $1.path } ?? []

    let mcm = try library.createGroup(name: "2026美赛B题")
    let refs = try library.createGroup(name: "参考文献", parentId: mcm.id)
    let data = try library.createGroup(name: "数据集", parentId: mcm.id)
    let night = try library.createGroup(name: "夜间场景")
    let seg = try library.createGroup(name: "医学图像分割")
    try library.createGroup(name: "论文辅导")

    let mustRead = try library.createTag(name: "必读", colorHex: "#FF3B30")
    let reproduce = try library.createTag(name: "待复现", colorHex: "#FF9500")
    let mamba = try library.createTag(name: "Mamba", colorHex: "#AF52DE")
    let longTag = try library.createTag(name: "视网膜血管分割方法综述", colorHex: "#34C759")
    let survey = try library.createTag(name: "综述", colorHex: "#007AFF")

    var ids: [String] = []
    for (index, paper) in papers.enumerated() {
        let file = work.appending(path: "paper-\(index).pdf")
        if index < real.count {
            try FileManager.default.copyItem(at: real[index], to: file)
        } else {
            try makePDF(at: file, lines: [paper.title, paper.authors.map { "\($0.1) \($0.0)" }.joined(separator: ", "),
                                          "Abstract", paper.abstract ?? "This paper studies \(paper.title.lowercased())."])
        }
        if index == 0 { annotate(file) }
        guard case .imported(let id, _) = try library.importFiles([file]).first else { continue }
        _ = try library.applyMetadata(metadata(for: paper), toStandalone: id, autoRename: true)
        ids.append(id)
    }
    // A second file (supplementary material) under the first item.
    let supplement = work.appending(path: "Supplementary Material.pdf")
    try makePDF(at: supplement, lines: ["Supplementary Material", "Additional ablation studies"])
    _ = try library.addFiles([supplement], toItem: ids[0], autoRename: false)

    try library.addItems([ids[0], ids[7], ids[9]], toGroup: refs.id, includeSubgroups: false)
    try library.addItems([ids[11]], toGroup: data.id, includeSubgroups: false)
    try library.addItems([ids[2], ids[4], ids[9]], toGroup: night.id, includeSubgroups: false)
    try library.addItems([ids[1], ids[3], ids[5], ids[6]], toGroup: seg.id, includeSubgroups: false)
    try library.setTag(mustRead.id, onItems: [ids[0], ids[2], ids[6]], enabled: true)
    try library.setTag(reproduce.id, onItems: [ids[0], ids[3]], enabled: true)
    try library.setTag(mamba.id, onItems: [ids[0], ids[3], ids[9]], enabled: true)
    try library.setTag(longTag.id, onItems: [ids[0], ids[5], ids[6]], enabled: true)
    try library.setTag(survey.id, onItems: [ids[7]], enabled: true)
    try library.updateItem(ids[0]) { $0.rating = 4; $0.readStatus = .reading }
    try library.updateItem(ids[1]) { $0.rating = 5; $0.readStatus = .read }
    try library.updateItem(ids[2]) { $0.readStatus = .read }

    // A standalone file whose retrieval failed, and one item in the trash.
    let loose = work.appending(path: "扫描版讲义 第三章.pdf")
    try makePDF(at: loose, lines: ["第三章 线性代数基础"])
    if case .imported(let id, _) = try library.importFiles([loose]).first {
        try library.setMetadataState(.failed, for: id)
    }
    try library.trashItems([ids[10]])
    // A file deleted on its own: shows in the trash with "来自：<item>" (TRASH-03).
    let extra = work.appending(path: "Rebuttal Letter.pdf")
    try makePDF(at: extra, lines: ["Response to reviewers"])
    if case .added(let fileId) = try library.addFiles([extra], toItem: ids[2], autoRename: false).first {
        try library.trashFiles([fileId])
    }
    print("demo library: \(root.path) — \(ids.count) items")
}

func bulk(root: URL, count: Int) throws {
    let library = try Library(root: root)
    let work = FileManager.default.temporaryDirectory.appending(path: "folio-bulk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let groups = try (0..<10).map { try library.createGroup(name: "分组 \($0 + 1)") }
    let tags = try (0..<8).map { try library.createTag(name: "标签\($0 + 1)", colorHex: ["#FF3B30", "#34C759", "#007AFF", "#AF52DE"][$0 % 4]) }
    let start = Date()
    for index in 0..<count {
        let paper = papers[index % papers.count]
        let file = work.appending(path: "bulk-\(index).pdf")
        try makePDF(at: file, lines: ["\(paper.title) (\(index))", "Body text \(index)"])
        guard case .imported(let id, _) = try library.importFiles([file]).first else { continue }
        var m = metadata(for: paper)
        m.title = "\(paper.title) — variant \(index)"
        m.doi = nil
        m.year = 2000 + index % 26
        _ = try library.applyMetadata(m, toStandalone: id, autoRename: true)
        try library.addItems([id], toGroup: groups[index % groups.count].id, includeSubgroups: false)
        try library.setTag(tags[index % tags.count].id, onItems: [id], enabled: true)
        try FileManager.default.removeItem(at: file)
    }
    print("bulk library: \(root.path) — \(count) items in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: folio-seed demo <dir> [--pdfs <dir>] | folio-seed bulk <dir> <count>")
    exit(2)
}
let root = URL(filePath: args[1], directoryHint: .isDirectory)
do {
    switch args[0] {
    case "demo":
        let pdfs = args.firstIndex(of: "--pdfs").flatMap { args.indices.contains($0 + 1) ? URL(filePath: args[$0 + 1]) : nil }
        try demo(root: root, realPDFs: pdfs)
    case "bulk":
        try bulk(root: root, count: Int(args[safe: 2] ?? "1000") ?? 1000)
    default:
        print("unknown command \(args[0])")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
