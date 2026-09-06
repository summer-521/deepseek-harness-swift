import SwiftUI

/// A native, coordinator-driven recovery surface. It only renders state from
/// `DshRecoveryViewModel`; lifecycle and runtime work stay outside the view.
public struct DshRecoveryView: View {
    @ObservedObject private var viewModel: DshRecoveryViewModel
    @State private var isDetailsExpanded = false
    @State private var isDiagnosticPreviewExpanded = false
    @State private var isPluginRemovalConfirmationPresented = false
    @State private var isAdoptConfirmationPresented = false
    @State private var hasRequestedPreview = false

    public init(viewModel: DshRecoveryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        recoveryContent
                        Spacer(minLength: 24)
                    }
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCard
            pluginFailureSection
            details
            diagnosticExport
            actions
        }
        .padding(24)
        .frame(width: 700, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("无法完成启动")
                .font(.title2.weight(.semibold))
            Text("可以重试，或打开设置检查运行环境。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(viewModel.phaseTitle)
                    .font(.headline)
                Spacer()
                if viewModel.isActionInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
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
                Text("错误码：\(code)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let actionMessage = viewModel.actionMessage ?? (viewModel.isActionInFlight ? "正在执行…" : nil) {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
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
                    Text("插件故障定位")
                        .font(.headline)
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
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            }

            if viewModel.canAdoptInterruptedTransaction {
                Button("验证当前状态并继续") {
                    isAdoptConfirmationPresented = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isActionInFlight || viewModel.pluginRemovalInFlight || viewModel.adoptInterruptedTransactionInFlight)
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
