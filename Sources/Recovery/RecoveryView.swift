import AppKit
import SwiftUI

/// Reports the vertical size of the recovery card so the owning window can
/// resize to fit the current content (for example when a disclosure expands
/// or collapses).
private struct DshRecoveryContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A native, coordinator-driven recovery surface. It only renders state from
/// `DshRecoveryViewModel`; lifecycle and runtime work stay outside the view.
public struct DshRecoveryView: View {
    @ObservedObject private var viewModel: DshRecoveryViewModel
    @State private var isDetailsExpanded = false
    @State private var isDiagnosticPreviewExpanded = false
    @State private var isPluginRemovalConfirmationPresented = false
    @State private var isAdoptConfirmationPresented = false
    @State private var hasRequestedPreview = false
    /// Reports the content's ideal height so the owning window can resize to
    /// fit when a disclosure expands or collapses. Runs on the main actor.
    private let onContentHeightChange: @MainActor (CGFloat) -> Void

    public init(
        viewModel: DshRecoveryViewModel,
        onContentHeightChange: @escaping @MainActor (CGFloat) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onContentHeightChange = onContentHeightChange
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView(.vertical) {
                recoveryContent
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DshRecoveryContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .onPreferenceChange(DshRecoveryContentHeightKey.self) { height in
                onContentHeightChange(height)
            }
        }
        .frame(width: 620)
        .confirmationDialog(
            "确认移除并重试？",
            isPresented: $isPluginRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移除所选插件并重试", role: .destructive) {
                _ = viewModel.requestRemovePluginAndRetry()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将修改原 desktop Profile。仅在唯一定位到非受管理插件且启动代次、Profile 路径仍有效时执行；恢复服务会先停止，无法确认归属的依赖不会被修改。")
        }
        .confirmationDialog(
            "验证当前状态并继续？",
            isPresented: $isAdoptConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("验证并继续", role: .destructive) {
                _ = viewModel.requestAdoptInterruptedTransaction()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将验证当前 desktop Profile 是否健康：健康则继续启动，不健康的包变更会自动从安装前快照恢复。快照完整时才可执行；不会静默保留未经验证的状态。")
        }
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            statusCard
                .padding(.bottom, 14)

            if viewModel.showsPluginFailureSection {
                pluginFailureSection
                    .padding(.bottom, 14)
            }

            details
                .padding(.bottom, 12)

            diagnosticExport
                .padding(.bottom, 20)

            Divider()
                .padding(.bottom, 16)

            actions
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .frame(width: 560, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("无法完成启动")
                    .font(.title2.weight(.semibold))
                Text("可以重试，或打开设置检查运行环境。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.orange.opacity(0.16))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(viewModel.phaseTitle)
                        .font(.headline)
                    if viewModel.isActionInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }

                Text(viewModel.failureSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = viewModel.portConflictHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let code = viewModel.failureCodeTitle {
                    Text(code)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("错误码：\(code)")
                }

                if let actionMessage = viewModel.actionMessage ?? (viewModel.isActionInFlight ? "正在执行…" : nil) {
                    Text(actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.26), lineWidth: 1)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isDetailsExpanded.toggle()
                    if isDetailsExpanded {
                        isDiagnosticPreviewExpanded = false
                        hasRequestedPreview = false
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                    Text(isDetailsExpanded ? "隐藏诊断详情" : "查看诊断详情")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isDetailsExpanded ? "已展开" : "已收起")

            if isDetailsExpanded {
                ScrollView {
                    Text(viewModel.redactedDetails)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 90, maxHeight: 220)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
        }
    }

    private var pluginFailureSection: some View {
        Group {
            if viewModel.showsPluginFailureSection, let analysis = viewModel.pluginFailureAnalysis {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.14))
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                        Text("插件故障定位")
                            .font(.headline)
                        Spacer()
                    }

                    Text(analysis.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(analysis.candidates.enumerated()), id: \.offset) { _, candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(candidate.resolution.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                Text(candidate.pluginName ?? "未识别插件")
                                    .font(.subheadline.monospaced())
                                Spacer()
                            }
                            ForEach(Array(candidate.evidence.prefix(3).enumerated()), id: \.offset) { _, evidence in
                                Text("· \(evidence.source.rawValue)：\(evidence.summary)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("移除计划：\(candidate.removalPlan.reason)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        }
                    }

                    if viewModel.canRequestPluginRemoval {
                        Button("移除所选插件并重试") {
                            isPluginRemovalConfirmationPresented = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            viewModel.pluginRemovalInFlight
                                || viewModel.isActionInFlight
                                || viewModel.adoptInterruptedTransactionInFlight
                        )
                    } else {
                        Text("当前仅提供只读定位；证据不唯一、共享依赖、web Profile、受管理组件或 patch 不完整时不会执行移除。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("重试") {
                    _ = viewModel.requestRetry()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    viewModel.isActionInFlight
                        || viewModel.pluginRemovalInFlight
                        || viewModel.adoptInterruptedTransactionInFlight
                )

                Button("打开设置") {
                    _ = viewModel.requestOpenSettings()
                }
                .buttonStyle(.bordered)
                .disabled(
                    viewModel.isActionInFlight
                        || viewModel.pluginRemovalInFlight
                        || viewModel.adoptInterruptedTransactionInFlight
                )

                Button("安全模式") {
                    _ = viewModel.requestSafeMode()
                }
                .buttonStyle(.bordered)
                .disabled(
                    !viewModel.isSafeModeAvailable
                        || viewModel.isActionInFlight
                        || viewModel.pluginRemovalInFlight
                        || viewModel.adoptInterruptedTransactionInFlight
                )
                .help(viewModel.safeModeAvailabilityDescription)
                if viewModel.canAdoptInterruptedTransaction {
                    Button("验证当前状态并继续") {
                        isAdoptConfirmationPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isActionInFlight || viewModel.pluginRemovalInFlight || viewModel.adoptInterruptedTransactionInFlight)
                }
            }
        }
    }

    private var diagnosticExport: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(isDiagnosticPreviewExpanded ? "隐藏导出预览" : "生成预览") {
                    if isDiagnosticPreviewExpanded {
                        isDiagnosticPreviewExpanded = false
                        hasRequestedPreview = false
                    } else if viewModel.refreshDiagnosticPreview() {
                        hasRequestedPreview = true
                        isDiagnosticPreviewExpanded = true
                        isDetailsExpanded = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)

                Button("复制诊断摘要") {
                    _ = viewModel.requestCopyDiagnosticSummary()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)

                Button("保存 JSON") {
                    _ = viewModel.requestSaveDiagnosticExport()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)
            }

            if hasRequestedPreview, let preview = viewModel.diagnosticPreview {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isDiagnosticPreviewExpanded.toggle()
                            if isDiagnosticPreviewExpanded {
                                isDetailsExpanded = false
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(isDiagnosticPreviewExpanded ? 90 : 0))
                            Text("诊断导出预览")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isDiagnosticPreviewExpanded ? "已展开" : "已收起")

                    if isDiagnosticPreviewExpanded {
                        ScrollView {
                            Text(preview)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(minHeight: 90, maxHeight: 240)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        }
                        Text("\(viewModel.diagnosticPreviewByteCount) bytes · 仅包含脱敏诊断信息")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
