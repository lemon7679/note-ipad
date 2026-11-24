# 설계

## 모듈

```
NoteApp (iOS, SwiftUI + UIKit + PDFKit)
 ├─ NoteKit (Foundation만 사용 — Linux에서 빌드·테스트)
 └─ InkBridge (Swift 래퍼) ── InkEngine (note-core, C++17, C API)
```

- **NoteKit**은 UI와 무관한 모든 것을 담습니다: 노트 파일 형식, 라이브러리 파일 조작, NAS 클라이언트, 동기화.
  `swift test`로 Linux/WSL에서 검증합니다(동기화는 임시 폴더를 가짜 NAS로 두 기기 시나리오까지).
- **InkBridge**는 엔진 C API를 Swift 타입(`StrokeBuilder`, `InkPage`, `PenSample` …)으로 감쌉니다.
  앱은 C API를 직접 부르지 않습니다. `Sources/InkBridgeStub`는 엔진 없이도
  앱 전체를 타입 검사할 수 있게 하는 동일 API의 빈 구현(`NOTE_ENGINE_STUB=1`)이며, `scripts/check-bridge-api.sh`가 두 API를 비교합니다.

## 캔버스 렌더링

note-core의 CPU 래스터라이저를 타일 단위로 씁니다(엔진 문서의 "타일 CPU 렌더러").

```
UIScrollView (확대 0.5–5×)
 └ CanvasContentView — 모든 터치를 CanvasViewController로
    └ PageView (화면 근처 페이지만 존재)
       ├ previewLayer    페이지 전체 저해상도 이미지(스크롤 중 빈 화면 방지)
       ├ tileContainer   512 px 타일 = 종이/PDF 배경 + 확정된 잉크
       ├ overlayContainer 그리는 중인 획(형광펜은 multiply 합성)
       ├ decoration      올가미 경로, 선택 상자/손잡이, 떠 있는 선택 이미지, 지우개 커서, 검색 강조
       └ ElementView     텍스트 상자·이미지(UIKit 뷰)
```

- **타일**: 렌더 배율(px/페이지 단위) = 레이아웃 배율 × 확대 단계 × 화면 배율. 확대 단계는 실제 확대 이상인
  약 1.26배 간격 값(2^(k/3))이라 조금 핀치해서는 타일을 다시 만들지 않습니다. 확대가 끝나면 새 배율의 타일을
  화면 가운데에 가까운 것부터 작업 스레드(`TileRenderQueue`, 코어 수 − 1, 최대 3개)에 맡기고, 다 만들어질 때까지
  이전 타일을 남겨 둡니다. 작업 스레드는 메인 스레드에서 잡은 엔진 스냅숏(`InkPage.snapshot()`, 변경 전까지 공유)을
  그리고, 결과는 그사이 타일이 바뀌지 않았을 때(epoch 비교)만 씁니다. 미리 보기도 같은 방식입니다.
  타일 = Core Graphics로 종이 템플릿 또는 PDF 페이지(PDF는 타일별로 배경 캐시, PDF 그리기는 잠금으로 한 번에 하나)
  → 스냅숏(또는 즉시 갱신 때 `InkPage.renderOver`)으로 같은 버퍼에 잉크 합성(형광펜 Multiply가 실제 PDF 글자 위에서 계산됨) → `CGImage`.
- **실시간 획**: 디스플레이 링크마다 `StrokeBuilder.tick`(도형 스냅, 햅틱) → `updateGeometry`가 돌려준
  변경 영역에 걸리는 오버레이 타일만 `StrokeBuilder.renderOver`로 다시 그립니다. 펜을 떼면 확정 →
  잉크 타일을 같은 프레임에 다시 그린 뒤 오버레이를 치우므로 깜빡임이 없습니다.
- **입력**: coalesced 터치 전부, predicted 터치, estimated 필압·기울기 갱신(`estimationUpdateIndex`),
  `preciseLocation`. Pencil 전용 모드에서 손가락은 스크롤/확대, 손가락 필기 모드에서는 두 손가락 스크롤.
  그리는 중 다른 손가락을 대면 `setShapeConstraint`(완벽한 도형).
- **올가미 이동**: 선택한 획을 `setHidden`으로 타일에서 빼고 `renderStrokesOver`로 떠 있는 레이어에 그려
  손가락을 따라가게 한 뒤, 놓을 때 `transform` 한 번(실행 취소 1단계)으로 확정합니다.
- **GPU로 바꾸기**: `PageView`의 타일/오버레이 부분만 Metal 구현(note-core `shaders/ink_stroke.metal`)으로
  바꾸면 나머지(입력, 모델, 동기화)는 그대로입니다.

## 편집 모델

- `EditorModel`이 노트 하나를 엽니다. 페이지 잉크(`InkPage`)는 필요할 때 `pages/<id>.ink`에서 불러옵니다.
- 실행 취소: 엔진이 페이지마다 이력을 갖고, 앱은 "어느 페이지를 고쳤는지"의 스택과 문서 구조 변경
  (페이지 추가·삭제·이동, 종이, 텍스트/이미지)의 스냅숏을 함께 쌓아 노트 전체에서 시간 순서대로 되돌립니다.
- 자동 저장: 편집 2초 뒤, 앱이 비활성화될 때, 노트를 닫을 때. 바뀐 페이지 파일만 다시 씁니다. 메인 스레드는 잉크
  스냅숏과 문서 값만 잡고, 직렬화 · 파일 쓰기 · 표지 썸네일은 직렬 큐에서 순서대로 합니다(동기 저장은 앞선 저장을 기다림).

## 저장소와 동기화

```
이 iPad:   Documents/                       (파일 앱에 보임)
NAS 계정:  Application Support/Note/Mirrors/<계정 ID>/   ⇄  NAS의 노트 폴더
상태:      Application Support/Note/Sync/<계정 ID>.json
휴지통:    Application Support/Note/Trash/<소스>/
```

앱은 항상 로컬(이 iPad 또는 미러)에서 읽고 씁니다. 그래서 오프라인에서도 똑같이 동작하고, 동기화는 뒤에서
`SyncEngine`(actor)이 합니다.

### SyncPlanner — 3-way 규칙 (순수 함수, 단위 테스트)

입력: 로컬 스캔(크기+수정 시각), NAS 목록(ETag 또는 크기+수정 시각), 지난 동기화 기록.

| 로컬 | NAS | 결과 |
|---|---|---|
| 바뀜 | 그대로 | 올림 |
| 그대로 | 바뀜 | 내려받음 |
| 삭제 | 그대로 | NAS에서 삭제 |
| 그대로 | 삭제 | 로컬에서 삭제 |
| 삭제 | 바뀜 / 바뀜 | 삭제 | 바뀐 쪽이 이김(복원) |
| 바뀜 | 바뀜 | **충돌** |
| 새 파일 | 새 파일 | 크기가 같으면 같은 것으로 간주, 다르면 충돌 |

- `.inknote` 안의 어떤 파일이라도 충돌이면 **노트 전체**를 충돌로 다룹니다(두 버전이 섞인 노트를 만들지 않음).
- 폴더가 한쪽에서 삭제되면, 다른 쪽에서 그 안이 바뀌지 않았을 때만 통째로 삭제합니다.
- PDF 등 노트가 아닌 새 파일은 "자리 표시자"로 기록만 하고, 열 때 `materialize`로 받습니다.
- 열려 있는 노트(busy)는 건너뛰고 다음 동기화에서 처리합니다.
- 해결 방법: 이 iPad 유지(강제 올림) / NAS 유지(강제 내려받기) / 둘 다 보관(로컬을 "(충돌 사본 …)"으로
  복제 → NAS 버전 받기 → 사본 올림).

### SyncEngine — 실행

- 실행 순서: 충돌 사본 → 폴더 생성(얕은 것부터) → 전송 → 삭제(깊은 것부터) → 상태만 바꾸는 항목.
- 다운로드는 `.sync-tmp`에 받은 뒤 제자리로 옮깁니다. 전송 10건마다 상태 저장(중단돼도 이어서).
- 인증·인증서·저장 공간 오류는 즉시 중단, 개별 파일 오류는 모아서 보고.
- 안전장치: 기록에 있던 NAS 항목이 5개 이상인데 NAS가 비어 보이면 중단, NAS 폴더가 사라졌으면 중단,
  로컬 미러가 통째로 비었으면 NAS를 지우지 않고 처음부터 다시 받음.

### NAS 클라이언트

| | Synology (File Station) | WebDAV | 파일 앱(SMB 등) |
|---|---|---|---|
| 목록 | `SYNO.FileStation.List` (1000개씩) | PROPFIND Depth: infinity → 안 되면 1 | FileManager |
| 변경 감지 | 크기 + mtime | ETag(없으면 크기 + mtime) | 크기 + mtime |
| 올리기 | `SYNO.FileStation.Upload` multipart(파일 파트 마지막, mtime 보존) | PUT (+ `X-OC-Mtime`) | 임시 파일 후 교체 |
| 폴더 | CreateFolder(force_parent) | MKCOL(상위부터) | createDirectory |
| 이동 | Rename / CopyMove(작업 완료까지 폴링) | MOVE(Overwrite: T) | moveItem |
| 인증 | 세션(sid), 만료 시 재로그인, 2단계 인증 + 기기 토큰 | Basic(선제 전송) + Digest | 보안 범위 북마크 |

`HTTPTransport`는 iOS·Linux 공통 비동기 URLSession 래퍼(취소 지원)이며, 자체 서명 인증서를 TOFU로 고정합니다.

## 노트 파일 형식

`document.json`(`NotebookDocument`, format 1)

```json
{
  "format": 1,
  "id": "…",
  "title": "선형대수 필기",
  "created": "2026-11-23T07:20:00Z",
  "modified": "2026-11-23T08:02:00Z",
  "cover": { "colorHex": "#2F5BD3" },
  "defaultPaper": { "template": "ruled", "color": "white", "spacing": 0 },
  "defaultSize": { "width": 595.28, "height": 841.89 },
  "pages": [
    {
      "id": "…",
      "size": { "width": 595.28, "height": 841.89 },
      "paper": { "template": "ruled", "color": "white", "spacing": 0 },
      "background": { "kind": "paper" },
      "bookmarked": false,
      "elements": [
        { "id": "…", "kind": "text", "frame": { "x": 80, "y": 120, "width": 240, "height": 28 },
          "text": "메모", "fontSize": 16, "colorHex": "#1C1C1E" }
      ]
    }
  ],
  "pdf": { "file": "source.pdf", "originalName": "운영체제_09강.pdf", "linkedPath": "/강의자료/운영체제_09강.pdf" },
  "lastPageIndex": 0
}
```

- PDF 페이지는 `"background": { "kind": "pdf", "pageIndex": 3 }`.
- 좌표는 모두 페이지 단위(pt, 좌상단 원점). 잉크(`pages/*.ink`)는 엔진의 버전 관리 바이너리입니다.
- 더 새로운 `format`의 노트는 열지 않습니다(데이터 보호).
