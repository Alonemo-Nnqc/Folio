import FolioCore
import SwiftUI

/// Shows "Zhang, Tengya; Gao, Feng; …" and switches to an editable list (add / remove / reorder).
struct AuthorsEditor: View {
    let authors: [Author]
    let onChange: ([Author]) -> Void
    @State private var editing = false
    @State private var draft: [EditableAuthor] = []

    struct EditableAuthor: Identifiable, Equatable {
        let id = UUID()
        var family: String
        var given: String
    }

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($draft) { $author in
                    HStack(spacing: 6) {
                        TextField("姓", text: $author.family).textFieldStyle(.roundedBorder)
                        TextField("名", text: $author.given).textFieldStyle(.roundedBorder)
                        Button { move(author.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(draft.first?.id == author.id)
                        Button { move(author.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(draft.last?.id == author.id)
                        Button { draft.removeAll { $0.id == author.id } } label: { Image(systemName: "minus.circle") }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                HStack {
                    Button("添加作者", systemImage: "plus") { draft.append(EditableAuthor(family: "", given: "")) }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("取消") { editing = false }
                    Button("完成") {
                        onChange(draft.filter { !$0.family.trimmingCharacters(in: .whitespaces).isEmpty }
                            .map { Author(family: $0.family.trimmingCharacters(in: .whitespaces),
                                          given: $0.given.trimmingCharacters(in: .whitespaces)) })
                        editing = false
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.small)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(authors.isEmpty ? "无作者" : authors.map(AuthorFormatter.full).joined(separator: "; "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    draft = authors.map { EditableAuthor(family: $0.family, given: $0.given) }
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑作者")
            }
            .font(.callout)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.indices.contains(target) else { return }
        draft.swapAt(index, target)
    }
}
