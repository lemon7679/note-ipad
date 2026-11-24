#if canImport(UIKit)
import InkBridge
import NoteKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NASAccount?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Apple Pencil로만 그리기", isOn: $app.settings.pencilOnly)
                    Toggle("두 손가락 탭: 실행 취소 · 세 손가락 탭: 다시 실행", isOn: $app.settings.tapGesturesUndo)
                    Toggle("낙서로 지우기", isOn: $app.settings.scribbleToErase)
                } header: {
                    Text("필기")
                } footer: {
                    Text("낙서로 지우기: 펜으로 글씨 위를 여러 번 왔다 갔다 문지르면 그 아래 필기가 지워집니다.")
                }
                Section("새 노트 기본값") {
                    Picker("종이", selection: $app.settings.defaultTemplate) {
                        ForEach(PaperTemplate.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("종이 색", selection: $app.settings.defaultPaperColor) {
                        ForEach(PaperColor.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("크기", selection: $app.settings.defaultSize) {
                        ForEach(PageSizePreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("가로 방향", isOn: $app.settings.defaultLandscape)
                }
                Section {
                    ForEach(app.accounts) { account in
                        HStack {
                            Image(systemName: account.kind.symbolName).foregroundStyle(NoteTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                Text("\(account.displayAddress) · \(account.syncFolder)")
                                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                            }
                            Spacer()
                            Button("설정") { editing = account }
                        }
                        .swipeActions {
                            Button("연결 해제", role: .destructive) { app.removeAccount(account.id) }
                        }
                    }
                    Button {
                        editing = NASAccount(name: "", kind: .synology, syncFolder: "/home/Notes")
                    } label: {
                        Label("저장소 연결", systemImage: "plus")
                    }
                } header: {
                    Text("NAS")
                } footer: {
                    Text("NAS의 노트 폴더는 이 iPad에 미러로 보관되어 오프라인에서도 열리고, 연결되면 양방향으로 동기화됩니다. 암호는 키체인에 저장됩니다.")
                }
                Section("정보") {
                    LabeledContent("필기 엔진", value: "InkEngine \(InkPage.engineVersion)")
                    LabeledContent("앱 버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .sheet(item: $editing) { account in NASConnectView(account: account).environmentObject(app) }
        }
    }
}
#endif
