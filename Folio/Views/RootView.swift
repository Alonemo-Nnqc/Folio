import FolioCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 380)
        } detail: {
            ItemListView(model: model)
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
                }
                .toolbar { toolbarContent }
        }
        .navigationTitle(model.title)
        .overlay(alignment: .bottom) { ToastOverlay(center: model.toasts) }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .identifierAdd: IdentifierAddSheet(model: model)
            case .manualMatch(let id): ManualMatchSheet(model: model, itemId: id)
            case .zoteroImport: ZoteroImportSheet(model: model)
            case .tagEditor(let tagId, let applyTo, let initialName):
                TagEditorSheet(model: model, tagId: tagId, applyTo: applyTo, initialName: initialName)
            }
        }
        .alert("无法打开文献库", isPresented: .constant(model.loadError != nil)) {
            Button("好") {}
        } message: {
            Text(model.loadError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.importer.refreshChangedFiles()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("添加文件…", systemImage: "doc.badge.plus") { model.chooseFilesToImport() }
                Button("通过标识符添加…", systemImage: "number") { model.activeSheet = .identifierAdd }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .help("添加文献")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("导出 BibTeX…", systemImage: "square.and.arrow.up") { model.exportBibTeX() }
                Divider()
                ForEach(CitationStyleOption.allCases) { style in
                    Button("复制 \(style.title) 引用") { model.copyCitations(style: style) }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出与复制引用")
            .disabled(model.snapshot.items.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .help(model.showInspector ? "隐藏检查器" : "显示检查器")
        }
    }
}
