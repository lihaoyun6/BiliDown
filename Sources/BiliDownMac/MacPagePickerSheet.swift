import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 多 P 视频的分 P 选择器。
/// 单 P 的直接回调 [1] 然后自己关掉 —— 没什么好选的，不该让用户白看一个弹窗。
/// 这儿不显示封面：都是同一个视频的分 P，封面全一样，摆了也是白占地方。
struct MacPagePickerSheet: View {

    let target: ParsedTarget
    /// 确认按钮的动词，收藏夹里用「选择」
    var confirmVerb: String = "添加"
    let onConfirm: ([Int]) -> Void

    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.dismiss) private var dismiss

    @State private var info: VideoInfo?
    @State private var selected: Set<Int> = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await load() }
    }

    private var header: some View {
        Text("选择视频")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在获取视频信息…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ListPlaceholder(
                icon: "exclamationmark.triangle",
                title: "无法获取视频信息",
                message: errorMessage
            )
            .frame(maxHeight: .infinity)
        } else if let info {
            List {
                Section {
                    // 全选：勾上是全选，再点一下全部取消
                    SelectAllRow(state: allState) { toggleAll() }

                    ForEach(info.pages) { page in
                        Button {
                            toggle(page.page)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(page.page) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(page.page) ? Color.accentColor : Color.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("P\(page.page) \(page.title)")
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(durationText(page.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(info.title)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || isLoading)
        }
        .padding(12)
    }

    private var allState: SelectAllRow.State {
        guard let count = info?.pages.count, count > 0, !selected.isEmpty else { return .none }
        return selected.count == count ? .all : .partial
    }

    /// 全勾上了就全取消，否则（空着或只勾了一部分）一律全选
    private func toggleAll() {
        guard let info else { return }
        if selected.count == info.pages.count {
            selected.removeAll()
        } else {
            selected = Set(info.pages.map(\.page))
        }
    }

    private var confirmTitle: String {
        selected.isEmpty ? confirmVerb : "\(confirmVerb) \(selected.count) 个"
    }

    private func toggle(_ page: Int) {
        if selected.contains(page) {
            selected.remove(page)
        } else {
            selected.insert(page)
        }
    }

    private func confirm() {
        onConfirm(selected.sorted())
        dismiss()
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func load() async {
        do {
            let info = try await queue.videoInfo(for: target.ref)

            guard info.isMultiPage else {
                // 单 P 没什么好选的，直接入队
                onConfirm([1])
                dismiss()
                return
            }

            self.info = info
            // 链接里写死了 ?p= 就先只勾那一 P（用户明确点过名），
            // 其它情况默认整季全勾，要少下几个自己去取消
            selected = target.page.map { Set([$0]) } ?? Set(info.pages.map(\.page))
            isLoading = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }
}
