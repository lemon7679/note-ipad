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
                    Picker("Pencil 두 번 탭", selection: $app.settings.pencilTapAction) {
                        ForEach(PencilButtonAction.tapActions) { Text($0.label).tag($0) }
                    }
                    Picker("Pencil Pro 쥐기 (스퀴즈)", selection: $app.settings.pencilSqueezeAction) {
                        ForEach(PencilButtonAction.squeezeActions) { Text($0.label).tag($0) }
                    }
                    Picker("페이지 넘기기", selection: $app.settings.pageLayout) {
                        ForEach(PageLayout.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("필기")
                } footer: {
                    Text("""
                        낙서로 지우기: 펜으로 글씨 위를 여러 번 왔다 갔다 문지르면 그 아래 필기가 지워집니다.
                        지우개 (지운 뒤 원래 도구로): 두 번 탭하면 지우개가 되고, 한 번 지우고 펜을 떼면 쓰던 도구로 돌아갑니다. 지우기 전에 다시 두 번 탭하면 취소됩니다.
                        쥐고 있는 동안 지우개: Apple Pencil Pro를 쥐고 있는 동안만 지우개가 되고, 손을 풀면 쓰던 도구로 돌아갑니다.
                        휠 메뉴: 펜 끝에 도구 · 색 · 굵기 · 펜 설정 휠이 열립니다.
                        옆으로 넘기기: 한 화면에 한 페이지씩 보이고, 손가락으로 옆으로 밀어 페이지를 넘깁니다.
                        """)
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
