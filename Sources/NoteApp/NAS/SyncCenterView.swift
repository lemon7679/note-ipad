#if canImport(UIKit)
import NoteKit
import SwiftUI

/// Sync status, activity and conflicts (design: SyncCenter artboard).
struct SyncCenterView: View {
    let focus: UUID?
    @EnvironmentObject private var app: AppModel

    private var accounts: [NASAccount] {
        guard let focus, let account = app.account(focus) else { return app.accounts }
        return [account] + app.accounts.filter { $0.id != focus }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("동기화").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button {
                        app.syncAll(manual: true)
                    } label: {
                        Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                Divider()
                if accounts.isEmpty {
                    Text("연결된 NAS가 없습니다.").foregroundStyle(NoteTheme.textSecondary).padding(20)
                }
                ForEach(accounts) { account in
                    AccountSyncSection(account: account)
                    Divider()
                }
            }
        }
        .background(NoteTheme.surface)
        .onAppear { app.loadConflicts() }
    }
}

private struct AccountSyncSection: View {
    let account: NASAccount
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let status = app.status(account.id)
        let conflicts = app.conflicts[account.id] ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: account.kind.symbolName).foregroundStyle(NoteTheme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(NoteTheme.Fonts.bodyEmphasized)
                        Text(status.summary).font(NoteTheme.Fonts.caption).foregroundStyle(statusColor(status))
                    }
                    Spacer()
                    if status.isSyncing, let p = status.progress, p.total > 0 {
                        Text("\(Int(p.fraction * 100))%").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NoteTheme.accent)
                    }
                }
                if status.isSyncing {
                    ProgressView(value: status.progress?.fraction ?? 0).tint(NoteTheme.accent)
                    if let item = status.progress?.currentItem {
                        Label(item, systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 13)).foregroundStyle(NoteTheme.textSecondary)
                    }
                } else if let report = status.lastReport, report.transferred > 0 || !report.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if report.uploaded > 0 { activity("arrow.up", "올림 \(report.uploaded)개", NoteTheme.accent) }
                        if report.downloaded > 0 { activity("arrow.down", "받음 \(report.downloaded)개", NoteTheme.textSecondary) }
                        if report.deletedLocal + report.deletedRemote > 0 {
                            activity("trash", "삭제 \(report.deletedLocal + report.deletedRemote)개", NoteTheme.textSecondary)
                        }
                        ForEach(report.errors.prefix(5), id: \.self) { message in
                            activity("exclamationmark.circle", message, NoteTheme.danger)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ForEach(conflicts) { conflict in
                ConflictCard(conflict: conflict) { resolution in
                    app.resolve(conflict, account: account.id, with: resolution)
                }
            }

            VStack(spacing: 0) {
                toggle("자동 동기화", \.autoSync)
                Divider()
                toggle("Wi-Fi에서만", \.wifiOnly)
                Divider()
                toggle("PDF는 열 때 내려받기", \.downloadOnDemand)
                Divider()
                toggle("충돌 시 둘 다 보관", \.keepBothOnConflict)
                Divider()
                toggle("PDF로도 내보내기", \.exportPDFCopies)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func statusColor(_ status: AccountSyncStatus) -> Color {
        switch status.phase {
        case .error: return NoteTheme.danger
        case .syncing: return NoteTheme.accent
        default: return NoteTheme.textSecondary
        }
    }

    private func activity(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 13)).lineLimit(2)
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<SyncOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { app.account(account.id)?.options[keyPath: key] ?? false },
            set: { value in app.updateOptions(account.id) { $0[keyPath: key] = value } }))
            .font(NoteTheme.Fonts.body)
            .tint(NoteTheme.accent)
            .frame(minHeight: 48)
    }
}

/// "물리 실험 보고서가 이 iPad와 NAS에서 모두 수정되었습니다" with the three choices.
private struct ConflictCard: View {
    let conflict: SyncConflict
    let resolve: (ConflictResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(NoteTheme.conflict)
                Text("충돌 · \(conflict.displayName)").font(NoteTheme.Fonts.bodyEmphasized).lineLimit(1)
            }
            Text("‘\(conflict.displayName)’이(가) 이 iPad(\(conflict.localModified?.relativeLabel ?? "-"))와 "
                 + "NAS(\(conflict.remoteModified?.relativeLabel ?? "-"))에서 모두 수정되었습니다.")
                .font(.system(size: 13)).foregroundStyle(NoteTheme.iconMuted)
            HStack(spacing: 8) {
                Button("이 iPad 유지") { resolve(.keepLocal) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("NAS 유지") { resolve(.keepRemote) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("둘 다 보관") { resolve(.keepBoth) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .font(.system(size: 14))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(NoteTheme.conflictSoft.opacity(0.5))
    }
}
#endif
