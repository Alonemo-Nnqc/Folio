import FolioMetadata
import SwiftUI

/// 设置 ▸ 检索 ▸ 期刊指标 (META-30): the easyScholar key, a test, and whether ranks are fetched by themselves.
struct JournalMetricsSettingsSection: View {
    @Bindable var settings: AppSettings
    let coordinator: JournalMetricsCoordinator
    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        Section {
            Toggle(isOn: $settings.journalMetricsAutoFetch) {
                Text("自动获取期刊分区与影响因子")
                Text("为有期刊名的条目获取中科院分区、JCR 分区和影响因子，同一期刊只查询一次并缓存 30 天")
            }
            .onChange(of: settings.journalMetricsAutoFetch) { coordinator.autoFetchDidChange() }

            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("easyScholar 密钥", text: $draft, prompt: Text("SecretKey"))
                        .labelsHidden()
                        .focused($keyFocused)
                        .onSubmit(commit)
                        .onChange(of: keyFocused) { _, focused in if !focused { commit() } }
                        .accessibilityIdentifier("easyScholarKey")
                    Button {
                        coordinator.test(draft)
                    } label: {
                        if coordinator.testState == .testing {
                            ProgressView().controlSize(.small).frame(width: 30)
                        } else {
                            Text("测试").frame(minWidth: 30)
                        }
                    }
                    .disabled(coordinator.testState == .testing || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("用该密钥查询一次 Nature 的指标")
                }
            } label: {
                Text("easyScholar 密钥")
                Link(destination: EasyScholarClient.keyPage) {
                    Text("如何获取密钥…")
                }
                .font(.caption)
                .help(EasyScholarClient.keyPage.absoluteString)
            }

            if let line = resultLine {
                HStack(spacing: 6) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(line.color)
                        .symbolRenderingMode(.hierarchical)
                    Text(line.text)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .transition(.opacity)
            }
        } header: {
            Text("期刊指标")
        } footer: {
            Text("数据由 easyScholar 开放接口免费提供：登录 easyScholar 后，在“开放接口”页面复制 SecretKey。密钥保存在钥匙串中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.smooth(duration: 0.2), value: coordinator.testState)
        .animation(.smooth(duration: 0.2), value: coordinator.status)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = coordinator.secretKey
            // Opening 设置 fills in whatever the library still lacks.
            coordinator.snapshotDidChange()
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        coordinator.saveKey(draft)
    }

    private var resultLine: (text: String, symbol: String, color: Color)? {
        switch coordinator.testState {
        case .success(let text): return (text, "checkmark.circle.fill", .green)
        case .failure(let text): return (text, "exclamationmark.triangle.fill", .orange)
        case .idle, .testing: break
        }
        guard coordinator.hasKey, let status = coordinator.statusText else { return nil }
        return switch status.tone {
        case .attention: (status.text, "exclamationmark.triangle.fill", .orange)
        default: (status.text, "arrow.triangle.2.circlepath", .accentColor)
        }
    }
}
