#if canImport(UIKit)
import Network
import NoteKit
import SwiftUI
import UniformTypeIdentifiers

/// Finds NAS boxes on the local network (Bonjour: SMB, AFP, WebDAV).
final class NASDiscovery: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let service: String
        var host: String?
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var searching = false
    private var browsers: [NWBrowser] = []
    private var resolvers: [String: NWConnection] = [:]
    private static let services = ["_smb._tcp", "_afpovertcp._tcp", "_webdav._tcp", "_webdavs._tcp"]

    func start() {
        guard browsers.isEmpty else { return }
        searching = true
        for type in Self.services {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                DispatchQueue.main.async { self?.update(results, service: type) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.searching = false }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        searching = false
    }

    private func update(_ results: Set<NWBrowser.Result>, service: String) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            // One row per box, whatever services it advertises.
            let id = name.lowercased()
            if !devices.contains(where: { $0.id == id }) {
                devices.append(Device(id: id, name: name, service: service, host: nil))
                resolve(result.endpoint, id: id)
            }
        }
    }

    private func resolve(_ endpoint: NWEndpoint, id: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                if let remote = connection?.currentPath?.remoteEndpoint, case let .hostPort(host, _) = remote {
                    let text: String
                    switch host {
                    case .ipv4(let address): text = "\(address)"
                    case .ipv6(let address): text = "\(address)"
                    case .name(let name, _): text = name
                    @unknown default: text = ""
                    }
                    DispatchQueue.main.async {
                        guard let self, let index = self.devices.firstIndex(where: { $0.id == id }) else { return }
                        self.devices[index].host = text.components(separatedBy: "%").first ?? text
                    }
                }
                connection?.cancel()
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.resolvers[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}

/// Add or edit a NAS connection (design: NasConnect artboard).
struct NASConnectView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = NASDiscovery()
    @State private var draft: NASAccount
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?
    @State private var pickingFolder = false
    @State private var pickingFilesFolder = false
    @State private var portText = ""
    private let isNew: Bool

    init(account: NASAccount) {
        _draft = State(initialValue: account)
        _portText = State(initialValue: account.port.map(String.init) ?? "")
        isNew = account.host.isEmpty && account.bookmark == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    kindPicker
                    if draft.kind == .filesFolder {
                        filesFolderSection
                    } else {
                        discoveredSection
                        serverSection
                        accountSection
                    }
                    optionsSection
                    testRow
                }
                .padding(24)
            }
            .background(NoteTheme.background)
            .navigationTitle(isNew ? "저장소 연결" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }.fontWeight(.semibold).disabled(!canSave)
                }
            }
        }
        .onAppear {
            if draft.kind != .filesFolder { discovery.start() }
        }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $pickingFolder) {
            RemoteFolderPicker(account: draft, password: password, otp: needsOTP ? otp : nil) { folder in
                draft.syncFolder = folder
            }
            .environmentObject(app)
        }
        .fileImporter(isPresented: $pickingFilesFolder, allowedContentTypes: [.folder]) { picked in
            guard case .success(let url) = picked else { return }
            do {
                draft.bookmark = try LocalFolderFileSystem.bookmark(for: url)
                draft.folderDisplayName = url.lastPathComponent
                if draft.name.isEmpty { draft.name = url.lastPathComponent }
                result = nil
            } catch {
                result = (false, "폴더에 접근할 수 없습니다. \(error.localizedDescription)")
            }
        }
    }

    private var canSave: Bool {
        draft.kind == .filesFolder ? draft.bookmark != nil : !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Sections

    private var kindPicker: some View {
        HStack(spacing: 10) {
            ForEach(NASKind.allCases) { kind in
                let selected = draft.kind == kind
                Button {
                    setKind(kind)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: kind.symbolName).font(.system(size: 22))
                            .foregroundStyle(selected ? NoteTheme.accent : NoteTheme.textSecondary)
                        Text(kind.displayName).font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundStyle(NoteTheme.textPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card)
                        .stroke(selected ? NoteTheme.accent : NoteTheme.separator, lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func setKind(_ kind: NASKind) {
        guard draft.kind != kind else { return }
        draft.kind = kind
        result = nil
        switch kind {
        case .synology:
            if draft.syncFolder == "/" || draft.syncFolder == "/Notes" { draft.syncFolder = "/home/Notes" }
            discovery.start()
        case .webdav:
            if draft.syncFolder == "/home/Notes" || draft.syncFolder == "/" { draft.syncFolder = "/Notes" }
            discovery.start()
        case .filesFolder:
            draft.syncFolder = "/"
            discovery.stop()
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "이 네트워크에서 찾음")
                Spacer()
                if discovery.searching {
                    ProgressView().controlSize(.small)
                    Text("Bonjour 검색 중…").font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                }
            }
            CardGroup {
                if discovery.devices.isEmpty {
                    Text(discovery.searching ? "찾는 중…" : "찾은 NAS가 없습니다. 주소를 직접 입력하세요.")
                        .font(NoteTheme.Fonts.body).foregroundStyle(NoteTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                ForEach(Array(discovery.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { CardDivider() }
                    let selected = device.host != nil && device.host == draft.host
                    Button {
                        if let host = device.host { draft.host = host }
                        if draft.name.isEmpty { draft.name = device.name }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack").foregroundStyle(selected ? NoteTheme.accent : NoteTheme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 15, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(NoteTheme.textPrimary)
                                Text("\(device.host ?? "주소 확인 중…") · \(serviceLabel(device.service))")
                                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                            }
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundStyle(NoteTheme.accent) }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(device.host == nil)
                }
            }
        }
    }

    private func serviceLabel(_ service: String) -> String {
        switch service {
        case "_smb._tcp": return "SMB"
        case "_afpovertcp._tcp": return "AFP"
        case "_webdavs._tcp": return "WebDAV (HTTPS)"
        default: return "WebDAV"
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "서버")
            CardGroup {
                FieldRow(label: "이름") { TextField("Home NAS", text: $draft.name) }
                CardDivider()
                FieldRow(label: "주소") {
                    HStack {
                        TextField("192.168.0.20 또는 nas.example.com", text: $draft.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text(":").foregroundStyle(NoteTheme.textSecondary)
                        TextField(String(draft.defaultPort), text: $portText)
                            .keyboardType(.numberPad)
                            .frame(width: 64)
                            .onChange(of: portText) { _, text in draft.port = Int(text) }
                    }
                }
                if draft.kind == .webdav {
                    CardDivider()
                    FieldRow(label: "서버 경로") {
                        TextField("/ 또는 /remote.php/dav/files/사용자", text: $draft.endpointPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                CardDivider()
                ToggleRow(title: "HTTPS", subtitle: nil, isOn: $draft.useHTTPS)
                CardDivider()
                ToggleRow(title: "자체 서명 인증서 신뢰",
                          subtitle: draft.pinnedCertificateSHA256 == nil ? "처음 연결한 인증서 지문을 기억합니다"
                              : "기억한 인증서: \(String(draft.pinnedCertificateSHA256!.prefix(23)))…",
                          isOn: $draft.allowSelfSigned)
                if draft.pinnedCertificateSHA256 != nil {
                    CardDivider()
                    Button("기억한 인증서 지우기") { draft.pinnedCertificateSHA256 = nil }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "계정")
            CardGroup {
                FieldRow(label: "사용자") {
                    TextField("사용자 이름", text: $draft.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                CardDivider()
                FieldRow(label: "암호") {
                    SecureField(isNew ? "암호" : "변경하지 않으려면 비워 두세요", text: $password)
                }
                if needsOTP {
                    CardDivider()
                    FieldRow(label: "인증 코드") {
                        TextField("2단계 인증 6자리", text: $otp).keyboardType(.numberPad)
                    }
                }
                CardDivider()
                Button {
                    pickingFolder = true
                } label: {
                    HStack {
                        Text("노트 폴더").frame(width: 110, alignment: .leading).foregroundStyle(NoteTheme.textPrimary)
                        Text(draft.syncFolder).foregroundStyle(NoteTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NoteTheme.offline)
                    }
                    .font(NoteTheme.Fonts.body)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(draft.host.isEmpty)
            }
            Text(draft.kind == .synology
                 ? "DSM의 공유 폴더 경로입니다. 예: /home/Notes (내 홈 폴더), /docs/Notes"
                 : "WebDAV 서버 안의 폴더입니다. 이 폴더가 iPad와 양방향으로 동기화됩니다.")
                .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).padding(.horizontal, 4)
        }
    }

    private var filesFolderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "SMB 공유 폴더")
            CardGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 파일 앱 › 둘러보기 › ⋯ › 서버에 연결에서 smb://NAS주소 로 공유 폴더를 추가합니다.")
                    Text("2. 아래에서 노트를 둘 폴더를 선택합니다. 이 폴더가 iPad와 동기화됩니다.")
                }
                .font(NoteTheme.Fonts.body)
                .foregroundStyle(NoteTheme.textSecondary)
                .padding(16)
                CardDivider()
                FieldRow(label: "이름") { TextField("SMB 공유 폴더", text: $draft.name) }
                CardDivider()
                Button {
                    pickingFilesFolder = true
                } label: {
                    HStack {
                        Text("폴더").frame(width: 110, alignment: .leading).foregroundStyle(NoteTheme.textPrimary)
                        Text(draft.folderDisplayName ?? "선택…").foregroundStyle(NoteTheme.accent)
                        Spacer()
                        Image(systemName: "folder").foregroundStyle(NoteTheme.accent)
                    }
                    .font(NoteTheme.Fonts.body)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "동기화")
            CardGroup {
                ToggleRow(title: "자동 동기화", subtitle: "앱을 열 때, 편집 후, 5분마다", isOn: $draft.options.autoSync)
                CardDivider()
                ToggleRow(title: "Wi-Fi에서만", subtitle: nil, isOn: $draft.options.wifiOnly)
                CardDivider()
                ToggleRow(title: "PDF는 열 때 내려받기", subtitle: "노트는 항상 iPad에 보관합니다",
                          isOn: $draft.options.downloadOnDemand)
                CardDivider()
                ToggleRow(title: "충돌 시 둘 다 보관", subtitle: "묻지 않고 충돌 사본을 만듭니다",
                          isOn: $draft.options.keepBothOnConflict)
                CardDivider()
                ToggleRow(title: "PDF로도 내보내기", subtitle: "노트 옆에 필기가 합쳐진 PDF를 함께 저장",
                          isOn: $draft.options.exportPDFCopies)
            }
        }
    }

    private var testRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Text("연결 테스트")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(testing || !canSave)
            if let result {
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark.circle" : "exclamationmark.circle")
                    Text(result.message).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 14))
                .foregroundStyle(result.ok ? NoteTheme.synced : NoteTheme.danger)
            }
        }
    }

    // MARK: Actions

    private func credentials() -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        store.setSecret(password.isEmpty ? app.credentials.secret(for: draft.passwordKey) : password, for: draft.passwordKey)
        store.setSecret(app.credentials.secret(for: draft.deviceTokenKey), for: draft.deviceTokenKey)
        return store
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let deviceKey = draft.deviceTokenKey
        let keychain = app.credentials
        do {
            let fs = try NASConnection.makeFileSystem(
                for: draft, credentials: credentials(), otpCode: needsOTP && !otp.isEmpty ? otp : nil,
                onPin: { fingerprint in
                    Task { @MainActor in draftPin(fingerprint) }
                },
                onDeviceToken: { token in keychain.setSecret(token, for: deviceKey) })
            let folder = draft.kind == .filesFolder ? "/" : draft.syncFolder
            var info: ServerInfo
            do {
                info = try await fs.testConnection(probeWrite: true, in: folder)
            } catch RemoteError.notFound {
                // The notes folder does not exist yet: create it.
                try await fs.createDirectory(folder)
                info = try await fs.testConnection(probeWrite: true, in: folder)
            }
            result = (true, "연결됨 · " + info.summary)
            needsOTP = false
        } catch RemoteError.twoFactorRequired {
            needsOTP = true
            result = (false, "2단계 인증 코드를 입력하고 다시 테스트하세요.")
        } catch {
            result = (false, error.localizedDescription)
        }
    }

    private func draftPin(_ fingerprint: String) {
        draft.pinnedCertificateSHA256 = fingerprint
    }

    private func save() {
        var account = draft
        if account.name.trimmingCharacters(in: .whitespaces).isEmpty {
            account.name = account.kind == .filesFolder ? (account.folderDisplayName ?? "SMB") : account.host
        }
        account.syncFolder = RemotePath.normalize(account.syncFolder)
        app.saveAccount(account, password: password.isEmpty ? nil : password)
        dismiss()
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            content
        }
        .font(NoteTheme.Fonts.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NoteTheme.Fonts.body)
                if let subtitle {
                    Text(subtitle).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                }
            }
        }
        .tint(NoteTheme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 48 : 56)
    }
}
#endif
