import SwiftUI

/// Sidebar: action row (新建分组 / 搜索文献), optional search panel, then the group outline (SIDE-02).
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.search.isVisible {
                searchPanel
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            SidebarOutline(model: model)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.search.isVisible)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Folio")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.createGroup()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("新建分组")
            .accessibilityIdentifier("newGroupButton")
            Button {
                if model.search.isVisible {
                    model.search = SearchState()
                } else {
                    model.showSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .symbolVariant(model.search.isVisible ? .circle.fill : .none)
            }
            .help("搜索文献")
            .accessibilityIdentifier("searchButton")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSearchField(text: $model.search.text, focusRequest: model.searchFocusRequest) {
                model.search = SearchState()
            }
            Picker("范围", selection: $model.search.wholeLibrary) {
                Text("当前分组").tag(false)
                Text("全部文献").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Toggle("包含 PDF 全文", isOn: $model.search.includeFulltext)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
