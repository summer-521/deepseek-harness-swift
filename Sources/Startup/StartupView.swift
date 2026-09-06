import AppKit
import SwiftUI

/// Observable startup progress rendered by `DshStartupView`. The owning
/// window controller and `MainWindowController` mutate it from MainActor-only
/// call sites; the view itself presents no sheets, alerts or authorization
/// windows.
@MainActor
public final class DshStartupStatusModel: ObservableObject {
    @Published public var phase: DshLaunchPhase = .preparing
    @Published public var detail: String? = nil

    public init() {}
}

/// SwiftUI startup card shown in its own normal macOS window. It renders the
/// app icon, title, an indeterminate progress bar, a per-phase checklist and
/// the current detail on the standard window background. The window supplies
/// the system rounded corners, border and drop shadow; only the title is
/// omitted.
public struct DshStartupView: View {
    @ObservedObject public var status: DshStartupStatusModel

    public init(status: DshStartupStatusModel) {
        self.status = status
    }

    private static var orderedPhases: [DshLaunchPhase] {
        DshLaunchPhase.allCases.filter { $0 != .ready }
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            card
                .padding(.top, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 500)
    }

    private var card: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                if let appIcon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                }
                Text(status.phase == .ready ? "已就绪" : "正在启动 DSH")
                    .font(.system(size: 20, weight: .semibold))
                Text("正在准备本地运行环境，请稍候")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .frame(height: 6)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(Self.orderedPhases.enumerated()), id: \.offset) { index, phase in
                    phaseRow(phase: phase, index: index)
                }
            }
            Text(status.detail ?? "DSH 正在建立受保护的启动会话。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 380)
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .padding(.horizontal, 30)
        .frame(width: 440)
    }

    private func phaseRow(phase: DshLaunchPhase, index: Int) -> some View {
        let order = Self.orderedPhases
        let currentIndex = order.firstIndex(of: status.phase) ?? order.count
        let symbol = if index < currentIndex {
            "checkmark.circle.fill"
        } else if index == currentIndex {
            "circle.circle.fill"
        } else {
            "circle"
        }
        let tint: Color = if index < currentIndex {
            .green
        } else if index == currentIndex {
            .accentColor
        } else {
            Color(nsColor: .tertiaryLabelColor)
        }
        let labelColor: Color = if index < currentIndex {
            .secondary
        } else if index == currentIndex {
            .primary
        } else {
            Color(nsColor: .tertiaryLabelColor)
        }
        let weight: Font.Weight = if index == currentIndex { .semibold } else { .regular }
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(tint)
            Text(phase.displayName)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(labelColor)
            Spacer()
        }
    }
}
