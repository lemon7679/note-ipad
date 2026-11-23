# Windows(WSL)에서 xtool로 빌드하기

Mac 없이 Windows의 WSL(Ubuntu)에서 [xtool](https://github.com/xtool-org/xtool)로 이 앱을 빌드하고
iPad에 설치하는 방법입니다. 한 번만 설정하면 이후에는 `xtool dev` 한 줄로 빌드·설치됩니다.

## 0. 준비물

- Windows 10 22H2 이상 / Windows 11, WSL2 + Ubuntu 24.04
- iPad와 USB 케이블
- Apple ID (무료 계정 가능 — 앱은 7일마다 다시 설치해야 함. 유료 개발자 계정이면 1년)
- [Xcode.xip](https://developer.apple.com/download/all/?q=Xcode) — xtool이 iOS SDK를 추출하는 데 씁니다.
  브라우저에서 Apple ID로 로그인해 내려받습니다(xtool 문서가 지정한 버전).

## 1. WSL과 USB 연결

PowerShell(관리자):

```powershell
wsl --install -d Ubuntu-24.04
winget install --interactive --exact dorssel.usbipd-win
```

iPad를 연결하고 PowerShell(관리자)에서 WSL에 붙입니다. 재부팅하거나 케이블을 다시 꽂으면 `attach`를 다시 합니다.

```powershell
usbipd list
```

```powershell
usbipd bind --busid <iPad의 BUSID>
```

```powershell
usbipd attach --wsl --busid <iPad의 BUSID>
```

> `AFCClient.Error.muxError`가 나면 xtool 문서의 안내대로 iTunes(Windows) 연결을 중계하는 방법을 쓰세요.

## 2. WSL 안에서 도구 설치

```bash
sudo apt-get update
sudo apt-get install -y usbmuxd libimobiledevice-utils git curl
```

Swift 툴체인(xtool 문서가 요구하는 버전)을 <https://swift.org/install/linux> 의 안내대로 설치합니다.
`swiftly`를 쓰면 간단합니다.

```bash
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup
```

```bash
swift --version
```

xtool:

```bash
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool
sudo mv xtool /usr/local/bin/
```

AppImage 실행에 FUSE가 필요하다는 오류가 나면:

```bash
sudo apt-get install -y libfuse2
```

## 3. xtool 설정 (한 번)

```bash
xtool setup
```

- 로그인 방식: 유료 개발자 계정이면 API Key, 아니면 Password(Apple ID + 2단계 인증)
- `Path to Xcode.xip:` 에 내려받은 파일 경로를 입력합니다. Windows 다운로드 폴더라면
  `/mnt/c/Users/<사용자>/Downloads/Xcode_XX.X.xip`

```bash
swift sdk list
```

`darwin`이 보이면 완료입니다.

## 4. 소스 받기

두 저장소를 **같은 폴더에 나란히** 받습니다. `Package.swift`가 `../note-core`를 자동으로 찾습니다.
WSL 파일 시스템(`~/…`)에 두세요. `/mnt/c` 아래는 빌드가 매우 느립니다.

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/lemon7679/note-core.git
git clone https://github.com/lemon7679/note-ipad.git
cd note-ipad
scripts/bootstrap.sh
```

note-core를 다른 곳에 두었다면(폴더 이름은 `note-core`여야 함):

```bash
export NOTE_CORE_PATH=/path/to/note-core
```

## 5. 빌드 · 설치 · 실행

iPad 잠금을 풀고 연결한 상태에서:

```bash
xtool dev
```

1. 처음에는 SwiftPM이 iOS SDK 모듈과 C++ 엔진을 빌드하느라 몇 분 걸립니다.
2. iPad에 "이 컴퓨터를 신뢰하시겠습니까?"가 뜨면 **신뢰** 후 다시 `xtool dev`.
3. "개발자 모드" 오류가 나면 iPad 설정 › 개인정보 보호 및 보안 › 개발자 모드를 켜고 재시동.
4. 처음 실행 시 "신뢰하지 않는 개발자"가 뜨면 설정 › 일반 › VPN 및 기기 관리 › (Apple ID) › 신뢰.

빌드만 하려면:

```bash
xtool dev build
```

결과 앱은 `./xtool/NoteApp.app`에 있습니다(Info.plist 확인용).

## 6. 편집기 설정 (선택)

VS Code + [Swift 확장](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)을
WSL 원격으로 열면 xtool이 만든 `.bsp/xtool.json` 덕분에 iOS SDK 기준으로 자동 완성·정의 이동이 됩니다.

## 7. 테스트

동기화 엔진·NAS 클라이언트·파일 형식 테스트는 iPad 없이 WSL에서 바로 돌릴 수 있습니다.

```bash
swift test
```

## 자주 겪는 문제

| 증상 | 해결 |
|---|---|
| `product 'InkEngine' required by package 'note-ipad' ... not found` | note-core가 `../note-core`에 없거나 오래된 버전입니다. `git -C ../note-core pull` |
| `xtool dev`가 기기를 못 찾음 | PowerShell에서 `usbipd attach --wsl --busid …`를 다시 실행, `ideviceinfo`로 확인 |
| 앱이 NAS를 못 찾음 | 처음 실행 시 "로컬 네트워크" 권한을 허용했는지 확인(설정 › 개인정보 보호 › 로컬 네트워크) |
| 7일 후 앱이 안 열림 | 무료 계정의 프로비저닝 만료입니다. `xtool dev`로 다시 설치(데이터는 유지) |
