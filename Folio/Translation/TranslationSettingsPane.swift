import SwiftUI

/// 设置 ▸ 翻译 (TRANS-02/03).
struct TranslationSettingsPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Text("翻译组件正在接入。")
            }
        }
        .formStyle(.grouped)
    }
}
