# Note — iPad 필기 앱 (NAS 중심)

[note-core](https://github.com/lemon7679/note-core)의 필기 엔진(InkEngine)으로 만든 iPad용 노트 앱입니다.
노트와 PDF를 **NAS(Synology · WebDAV · SMB)** 에 두고 iPad에서 오프라인으로 쓰다가 양방향으로 동기화합니다.
Mac 없이 **Windows(WSL) + xtool**로 빌드·설치합니다.

UI/UX는 Claude Design 캔버스([Note iPad UI](https://claude.ai/artifact/5HvTjuoJ1QG55RiZrQMPTG))에서 먼저 설계한 뒤
그 화면과 토큰("Quiet Ink")을 SwiftUI/UIKit 코드로 옮겼습니다. 자세한 대응은 [docs/DESIGN.md](docs/DESIGN.md).

## 기능

**라이브러리 · 파일 관리**
- 저장소: 이 iPad(파일 앱에 보임) + 연결한 NAS들. 폴더, 노트, PDF, 기타 파일
- 새 노트(표지 7색 · 종이 7종 · A4/B5/A5/Letter/화면 · 직접 입력(mm) · 세로/가로 · 종이 색), PDF 가져와서 필기, 파일 가져오기
- 이름 변경, 이동(끌어서 폴더에 놓기 포함, 이 iPad의 PDF · 파일은 NAS 폴더로도), 복제, 즐겨찾기, 최근 문서, 검색, 정렬
- 휴지통(복원 · 영구 삭제), 파일 앱/다른 앱에서 "Note로 열기"

**NAS 연동**
- **Synology DSM**: File Station API(5000/5001 포트) — WebDAV 패키지 없이 동작, 2단계 인증(OTP + 기기 토큰)
- **WebDAV**: Synology/QNAP/TrueNAS/OMV/Nextcloud 등. Depth: infinity를 지원하지 않으면 자동으로 폴더별 조회
- **SMB · 파일 앱**: 파일 앱의 "서버에 연결"로 추가한 공유 폴더를 보안 범위 북마크로 연결
- Bonjour로 같은 네트워크의 NAS 자동 검색, 연결 테스트(쓰기 권한 확인), NAS 폴더 선택기
- 자체 서명 인증서: 처음 본 인증서 지문을 기억(TOFU)하고, 바뀌면 연결을 거부
- 암호와 DSM 기기 토큰은 키체인에 저장
- **동기화**: NAS의 노트 폴더를 iPad에 미러로 두고 3-way 비교로 양방향 동기화
  - 노트는 페이지 단위 파일이라 바뀐 페이지만 전송
  - 양쪽에서 같은 노트를 고치면 충돌로 표시 → "이 iPad 유지 / NAS 유지 / 둘 다 보관"(설정으로 자동 보관 가능)
  - PDF 등 일반 파일은 목록만 받아 두고 열 때 다운로드(용량 절약), "다운로드 항목 제거" 가능
  - 앱 실행·복귀·편집 후·5분마다 자동, Wi-Fi에서만 옵션, 백그라운드 진입 시 마무리
  - 안전장치: NAS가 갑자기 비어 보이거나 폴더가 사라지면 아무것도 지우지 않고 멈춤
  - 열려 있는 노트는 닫힐 때까지 동기화를 미룸
- **NAS 전체 보기**: 동기화 폴더 밖의 PDF도 열람하고 노트 폴더로 가져오기
- 옵션: 노트를 닫을 때 필기가 합쳐진 PDF를 노트 옆에 함께 저장(NAS에서 바로 보기용)

**필기 (InkEngine)**
- 볼펜 · 만년필 · 연필 · 붓펜 · 캘리그라피 · 마커 · 형광펜, 색 팔레트 + 사용자 색, 굵기 프리셋 3개
- Apple Pencil 240 Hz coalesced/predicted/estimated 입력, 필압·기울기
- 그리고 멈추면 도형(두 번째 손가락으로 완벽한 도형), 형광펜 직선 스냅, 글씨 보정, 손떨림 보정
- 정밀/획 지우개(정밀 지우개는 닿은 부분만 정확히 지움), 형광펜만 지우기
- **낙서로 지우기**: 펜으로 글씨 위를 여러 번 왔다 갔다 문지르면 그 아래 필기가 지워짐(실행 취소 가능, 설정에서 끌 수 있음)
- 올가미: 이동, 모서리로 크기 조절, 복사·잘라내기·붙여넣기(페이지 간), 복제, 색 변경, **줄 정렬**, **글씨 다듬기**, 삭제
- 텍스트 상자, 이미지 삽입, 레이저 포인터
- 페이지 목록(썸네일, 끌어서 순서 변경, 앞/뒤 추가, 복제, 삭제, 책갈피), 종이 바꾸기, 표지 바꾸기
- **선택한 페이지로 새 노트 만들기**: PDF 노트 등에서 페이지를 골라 같은 폴더에 별도의 노트로(필기 · 이미지 · 책갈피 포함, 원본은 그대로)
- 실행 취소/다시 실행(페이지 편집 포함), 두 손가락 탭 실행 취소 · 세 손가락 탭 다시 실행, Pencil 더블 탭(2세대) · 스퀴즈(Pro)로 펜 끝에 굿노트식 도구 팔레트(도구 · 굵기 · 색 · 펜 종류 · 실행 취소/다시 실행 · 펜 설정) — 설정에서 지우개 전환으로 바꿀 수 있음
- **메뉴 숨기기(전체 화면)**: 상단 바 · 도구 줄 · 페이지 목록 · 상태 막대까지 숨기고 페이지만 표시. 오른쪽 위의 작은 버튼으로 돌아옴(Pencil 더블 탭 · 스퀴즈 도구 팔레트는 그대로 사용 가능)
- 연속 세로 스크롤 또는 **옆으로 넘기기**(한 화면에 한 페이지, 밀어서 넘김), 0.5×–5× 확대, Pencil 전용 모드(손가락은 스크롤) / 손가락 필기 모드
- 내보내기: 벡터 PDF(원본 PDF 위에 필기), 페이지 이미지, NAS 폴더에 PDF 저장

**PDF 뷰어**
- PDFKit 연속 보기, 목차, 페이지 썸네일, 문서 내 검색(이전/다음), 페이지 스크러버, 공유
- "필기 시작": 원본 PDF는 그대로 두고 옆에 `<PDF> 필기.inknote`를 만들어 필기(다시 열면 같은 노트로)
- 필기 노트에서도 PDF 목차·검색(검색어 위치 강조)

## 설치 (릴리스 IPA)

[Releases](https://github.com/lemon7679/note-ipad/releases)에서 `NoteApp-<버전>.ipa`(서명되지 않은 IPA)를 받아
자신의 Apple ID로 서명해 설치합니다.

```bash
xtool install NoteApp-0.1.0.ipa
```

Sideloadly · AltStore 같은 사이드로딩 도구도 쓸 수 있습니다. 새 릴리스는 Actions › **Release** › Run workflow에
버전을 넣으면 IPA를 빌드해 올립니다(릴리스 노트: `docs/releases/v<버전>.md`).

## 빌드 (Windows + WSL + xtool)

요약은 아래와 같고, 처음 설정은 [docs/BUILD_WSL.md](docs/BUILD_WSL.md)를 따라 하세요.

```bash
# 1) 두 저장소를 나란히 받기
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/lemon7679/note-core.git
git clone https://github.com/lemon7679/note-ipad.git
cd note-ipad
```

```bash
# 2) 환경 점검 (Swift, xtool, usbmuxd, note-core 위치)
scripts/bootstrap.sh
```

```bash
# 3) iPad를 USB로 연결(usbipd로 WSL에 붙임)한 뒤 빌드 → 서명 → 설치
xtool dev
```

- `Package.swift`는 note-core를 `$NOTE_CORE_PATH` → `../note-core` → GitHub(`main`) 순서로 찾습니다.
- 첫 빌드는 iOS SDK 모듈을 만드느라 몇 분 걸립니다. 이후에는 빠릅니다.
- 무료 Apple ID로도 설치됩니다(7일마다 다시 `xtool dev`). 번들 ID에는 xtool이 접두사를 붙입니다.

Linux/WSL에서 핵심 로직 테스트(동기화, NAS 클라이언트, 파일 형식):

```bash
swift test
```

## 구조

```
Package.swift          SwiftPM (xtool은 라이브러리 제품 NoteApp을 앱으로 묶음)
xtool.yml              번들 ID, Info.plist, 아이콘
Resources/             Info.plist(문서 형식·로컬 네트워크·Bonjour·ATS), AppIcon.png
Sources/
  NoteKit/             플랫폼 독립 핵심 — Linux에서 빌드·테스트
    Models/            NotebookDocument, 종이 템플릿, 페이지 크기
    Storage/           .inknote 패키지, 라이브러리 파일 시스템, 휴지통
    Remote/            RemoteFileSystem: SynologyClient, WebDAVClient, LocalFolderFileSystem, TLS
    Accounts/          NAS 계정, 키체인, 클라이언트 생성
    Sync/              SyncPlanner(3-way 규칙, 순수 함수), SyncEngine(actor)
    Export/            InkEngine SVG → 벡터 윤곽 (PDF 내보내기)
  InkBridge/           note-core C API의 Swift 래퍼
  InkBridgeStub/       CI 전용 대역(엔진 없이 앱 타입 검사)
  NoteApp/             앱 (SwiftUI + UIKit + PDFKit)
    Theme/             디자인 토큰(Quiet Ink), 공용 컴포넌트
    App/               AppModel(소스·계정·동기화·즐겨찾기), 설정
    Library/           사이드바, 폴더 화면, 새 노트, 이동, 최근/즐겨찾기, 휴지통
    NAS/               연결(검색·테스트·OTP), 폴더 선택, NAS 전체 보기, 동기화 센터
    Editor/            EditorModel(페이지·실행 취소·자동 저장), 편집기 화면, 펜 설정, 페이지 목록
    Editor/Canvas/     캔버스: 타일 렌더러, Pencil 입력, 올가미, 레이저, 텍스트/이미지
    PDF/               PDF 뷰어
Tests/NoteKitTests/    파일 형식, WebDAV/Synology 파싱, 동기화 시나리오(두 기기 + 가짜 NAS)
docs/                  BUILD_WSL.md, ARCHITECTURE.md, DESIGN.md
```

설계 상세(렌더링 파이프라인, 동기화 규칙, 파일 형식)는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 노트 파일 형식

```
선형대수 필기.inknote/        (디렉터리 패키지, UTI com.lemon7679.note.inknote)
  document.json               제목, 표지, 페이지 목록(크기·종이·PDF 페이지·텍스트/이미지), PDF 출처
  pages/<페이지 UUID>.ink      InkEngine 페이지 데이터(페이지마다 한 파일)
  assets/source.pdf           가져온 PDF 원본
  assets/<UUID>.jpg           삽입한 이미지
  thumbnail.png               라이브러리 표지용 첫 페이지
```

## CI

`.github/workflows/ci.yml` — note-core를 함께 받아 실제 엔진으로 검사합니다.
- Linux: NoteKit·엔진 브리지 빌드와 테스트, InkBridge 대역 API 일치 검사
- macOS: 앱 전체를 iOS 시뮬레이터용으로 빌드(실제 엔진, 엔진 대역 두 가지)
- iPad 시뮬레이터 실행: xtool과 같은 방식으로 라이브러리를 앱으로 묶어(`ci/AppBuilder`, `ci/make_app.py`)
  iPad Pro 11″ 시뮬레이터에 설치하고, 데모 데이터(DEBUG 전용 `-NoteDemoScreen`)로 라이브러리 · 편집기 ·
  PDF 뷰어 · NAS 연결 · 설정 화면을 띄워 충돌 여부를 확인하고 스크린샷을 로그에 남깁니다.

## 알려진 한계 / 다음 단계

- 캔버스는 CPU 타일 렌더러입니다. 스크롤·확대용 타일은 작업 스레드에서 엔진 스냅숏(`ink_snapshot_render_over_rgba`)으로
  그리고, 그리는 중인 획은 `ink_builder_render_over_rgba`로 겹쳐 그립니다. Android의 GPU(OpenGL ES) 렌더러에 해당하는
  Metal 렌더러는 다음 단계입니다.
- 이 저장소의 코드는 실기기에서 아직 손으로 검증하지 않았습니다. 펜 파라미터(엔진 프리셋)는 실제 Apple Pencil로
  다듬을 필요가 있습니다.
- SMB는 파일 앱 경유입니다(앱 안의 SMB 클라이언트 없음). 파일 앱의 SMB 연결은 iPadOS가 관리합니다.
- 한 노트를 두 기기에서 동시에 고치면 페이지 단위 병합 대신 노트 단위 충돌로 처리합니다.
