# 디자인 → 코드

UI/UX는 Claude Design 캔버스에서 먼저 그렸습니다: **[Note iPad UI](https://claude.ai/artifact/5HvTjuoJ1QG55RiZrQMPTG)**
(iPad Pro 11″ 가로 1194×834 pt 기준 아트보드 7개). 캔버스는 비공개이므로 다른 사람에게 보여 주려면
캔버스의 Share 메뉴에서 공유하세요.

## 아트보드 → 코드

| 아트보드 | 화면 | 코드 |
|---|---|---|
| 라이브러리 · NAS | 사이드바(라이브러리/저장소/동기화 카드), 경로 헤더, 칩, 폴더 카드, 노트·PDF 카드와 동기화 배지 | `Library/RootView.swift`, `Library/LibraryView.swift` |
| 노트 편집기 | 상단 바(52), 도구 줄(56), 페이지 목록(132), 올가미 메뉴, 쪽 표시, 도형 힌트 | `Editor/NotebookEditorView.swift`, `Editor/Canvas/*` |
| PDF 뷰어 | 읽기/필기 전환, 목차·페이지 탭, 검색 막대, 스크러버, "필기 노트로 열기" | `PDF/PDFReaderView.swift` |
| 저장소(NAS) 연결 | 방식 카드 3개, Bonjour 검색 목록, 서버/계정 그룹, 연결 테스트 | `NAS/NASConnectView.swift` |
| 새 노트 | 빈 노트/PDF/폴더, 표지 색, 종이 템플릿 6+1종, 크기·방향, 저장 위치 | `Library/LibrarySheets.swift` |
| 동기화 센터 | 진행률, 활동, 충돌 카드(이 iPad 유지 / NAS 유지 / 둘 다 보관), 옵션 | `NAS/SyncCenterView.swift` |
| 디자인 토큰 | 색·타이포·모양·컴포넌트 | `Theme/NoteTheme.swift`, `Theme/Components.swift` |

## 토큰 ("Quiet Ink")

| 역할 | 라이트 | 다크 | 코드 |
|---|---|---|---|
| background | `#F6F7F9` | `#111317` | `NoteTheme.background` |
| sidebar | `#EEF0F3` | `#171A1F` | `NoteTheme.sidebar` |
| desk (캔버스 바탕) | `#E9EBEF` | `#0B0C0F` | `NoteTheme.desk` |
| surface | `#FFFFFF` | `#1E2128` | `NoteTheme.surface` |
| separator | `#E2E5EA` | `#2C3038` | `NoteTheme.separator` |
| textPrimary / Secondary | `#15171C` / `#5B616E` | `#F2F3F5` / `#A3A9B5` | `NoteTheme.textPrimary` … |
| accent / accentSoft | `#2F5BD3` / `#E8EEFC` | `#7A9CFF` / `#1F2A47` | `NoteTheme.accent` … |
| synced / conflict / danger / offline | `#1F7A55` / `#B45309` / `#C0362C` / `#9AA0AC` | 밝게 조정 | 동기화 배지·상태 |
| paperRule / paperMargin | `#DCE3F0` / `#F2C9C9` | (종이는 항상 밝음) | `PaperRenderer` |

- 모양: 버튼·입력 radius 10 · 높이 40–44, 카드 14, 시트 18–20, 칩·배지 캡슐, 터치 영역 최소 44×44.
- 간격: 4 · 8 · 12 · 16 · 20 · 24 · 28(페이지 여백).
- 글자: 시스템 글꼴(SF Pro / Apple SD 산돌고딕 Neo). 28 bold 대제목, 22 semibold 폴더 제목, 17 semibold 시트 제목,
  15 본문, 13 semibold 섹션 레이블, 12 보조. 디자인 캔버스는 웹 미리보기용으로 Inter + Noto Sans KR을 썼습니다.
- 아이콘: 디자인의 선 아이콘을 같은 의미의 SF Symbols로 옮겼습니다(예: 펜 `pencil.tip`, 형광펜 `highlighter`,
  올가미 `lasso`, NAS `server.rack`, 동기화 `arrow.triangle.2.circlepath`).
- 펜 색: `#1C1C1E #1F4FD1 #D12F2F #12805C #7A3FC4 #E07A1F`, 형광펜: `#FFE45C #8EF0A8 #7FD3FF #FF9ECF`.
