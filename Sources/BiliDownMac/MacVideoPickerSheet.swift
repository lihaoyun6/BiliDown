import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 挑合集或 UP 主投稿里的视频。做法和分 P 选择器一样（全选、一个个勾、确认），
/// 只是条目多得多：每条都带封面，而且滚到底就接着往后拉。
/// 挑的结果只说「全都要，除了哪几个」或「只要哪几个」，所以
/// 没拉下来的那些也照样算数，按钮上的数量从第一屏起就是真的。
struct MacVideoPickerSheet: View {

    /// 顶上那行小字：合集名或者 UP 主名
    let listTitle: String
    let videos: [BulkVideo]
    /// 来源一共多少个视频，用来算「全都要」时到底要了多少
    let total: Int
    let isLoadingMore: Bool
    let selection: VideoSelection
    var onLoadMore: () async -> Void
    let onConfirm: (VideoSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var picked: VideoSelection = .all(except: [])

    var body: some View {
        VStack(spacing: 0) {
            Text("选择视频")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Divider()

            List {
                Section {
                    SelectAllRow(state: picked.checkState) {
                        picked = picked.toggledAll
                    }

                    ForEach(videos) { video in
                        Button {
                            picked = picked.toggling(video.bvid)
                        } label: {
                            row(video)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if video.bvid == videos.last?.bvid {
                                Task { await onLoadMore() }
                            }
                        }
                    }

                    if isLoadingMore {
                        LoadMoreSpinner()
                    }
                } header: {
                    Text(listTitle)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { picked = selection }
    }

    private func row(_ video: BulkVideo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: picked.contains(video.bvid) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(picked.contains(video.bvid) ? Color.accentColor : Color.secondary)

            CoverThumbnail(
                url: video.coverURL,
                width: 64,
                height: 40,
                badge: video.isMultiPage ? nil : durationText(video.duration)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                // 单 P 的时长搬到封面角标上了，这儿留一行空的：
                // 空着不是省掉 —— 不留的话单 P 那几行会比多 P 的矮一截，
                // 一列扫下来高矮不齐。
                Text(video.isMultiPage ? "共 \(video.pageCount) P" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var confirmTitle: String {
        picked.isEmpty ? "选择" : "选择 \(picked.count(total: total)) 个"
    }

    private func confirm() {
        onConfirm(picked)
        dismiss()
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
