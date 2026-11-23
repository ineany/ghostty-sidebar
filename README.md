# Ghostty Sidebar

Ghostty 옆에 세로 탭 목록을 띄우는 macOS 앱이다.
Ghostty를 고치지 않고, Ghostty의 AppleScript 사전과 macOS 손쉬운 사용 API로 탭을 읽고 창을 옮긴다.
Claude Code 세션의 상태, 비용, 자동 저장과 복원을 함께 보여 준다. Codex 세션도 자동 저장하고 복원한다.

## 기능

| 기능 | 설명 |
|---|---|
| 세로 탭 목록 | 모든 Ghostty 창의 탭을 1초마다 읽어 보여 준다. 클릭하면 그 탭으로 전환한다. |
| Claude 상태 | 탭 제목의 기호로 대기와 작업 중을 구분한다. 대기는 초록 점, 작업 중은 회전 표시다. |
| 세션 비용 | 탭마다 Claude 세션의 API 환산 비용을 보여 준다. 하단에는 오늘 쓴 비용의 합계를 보여 준다. |
| 세션 목록 저장 | 열려 있는 Claude 세션과 Codex 세션의 목록을 사이드바 전용 폴더에 저장한다. |
| 닫힌 세션 복원 | 다시 열 수 있는 세션을 접힌 그룹으로 보여 준다. 클릭하면 새 탭에서 `claude --resume` 또는 `codex resume`으로 연다. |
| 프로젝트별 보기 | 설정의 "프로젝트별로 묶기"를 켜면 탭을 git 저장소 단위로 묶는다. 머리글에 대기 수, 작업 중 수, 비용 합계를 보여 주고 "+"로 그 프로젝트에서 새 Claude 세션을 연다. 닫힌 세션도 프로젝트별로 묶는다. |
| 새 탭 | 머리글의 "+"로 최근 폴더나 고른 폴더에서 새 Claude 세션이나 셸 탭을 연다. |
| 창 붙이기 | 탭을 클릭하면 그 Ghostty 창을 사이드바 오른쪽에 붙인다. 붙인 창은 사이드바를 따라 움직인다. |
| 이동과 크기 조절 | 머리글을 끌어 옮기고, 오른쪽과 아래쪽 끝을 끌어 크기를 바꾼다. 다른 모니터로도 옮길 수 있다. |
| 자동 숨기기 | Dock처럼 마우스가 벗어나면 숨고, 화면 왼쪽 끝에 닿으면 나타난다. |

설정은 머리글의 설정 버튼, 사이드바의 오른쪽 클릭 메뉴, 메뉴 막대 아이콘에서 바꾼다.

## 설치

```
scripts/build-app.sh --install
```

스크립트는 앱을 빌드해 `~/Applications/Ghostty Sidebar.app`에 설치하고 실행한다.
`--install` 없이 실행하면 `build/` 폴더에만 만든다.

### 배포본

```
scripts/make-dmg.sh
```

스크립트는 Apple Silicon과 Intel에서 모두 도는 앱을 빌드하고 `build/Ghostty-Sidebar-<버전>.dmg`를 만든다.
DMG를 열고 앱을 Applications 폴더로 끌어 놓으면 설치된다.

Apple Development 인증서로 서명한 앱은 공증을 받지 않았으므로, 다른 Mac의 Gatekeeper가 첫 실행을 막는다.
받은 사람은 다음 중 한 가지로 연다.

1. Finder에서 앱을 오른쪽 클릭하고 "열기"를 고른다. 이후에는 그냥 열린다.
2. 터미널에서 `xattr -dr com.apple.quarantine "/Applications/Ghostty Sidebar.app"`를 실행한다.

경고 없이 배포하려면 Developer ID Application 인증서로 서명하고 `notarytool`로 공증을 받아야 한다.
이 인증서는 유료 Apple Developer Program에 가입해야 발급된다.

### 권한

처음 실행하면 macOS가 두 가지 권한을 묻는다.

1. 자동화: Ghostty와 System Events를 제어하는 권한이다. 탭 목록을 읽고 탭을 전환할 때 쓴다.
2. 손쉬운 사용: 다른 앱의 창을 옮기는 권한이다. 창 붙이기와 자동 정렬에 쓴다. 권한이 없으면 사이드바 아래에 안내 상자가 나타난다.

macOS는 손쉬운 사용 권한을 앱의 서명에 묶는다.
빌드 스크립트는 키체인의 첫 번째 Apple Development 인증서로 서명하므로, 다시 빌드해도 권한이 유지된다.
다른 인증서를 쓰려면 `SIGN_ID`에 인증서 이름을 넣는다. `SIGN_ID=-`로 실행하면 임시 서명을 쓰며, 이때는 빌드할 때마다 권한을 다시 켜야 한다.

예전 서명으로 켠 권한이 남아 동작하지 않으면 다음 명령으로 지우고 다시 켠다.

```
tccutil reset Accessibility dev.local.ghostty-sidebar
```

## 세션 목록과 복원

역할은 다음과 같이 나뉜다.

| 대상 | 저장 주체 |
|---|---|
| 대화 내용 | Claude Code와 Codex가 각자의 폴더에 저장한다. 사이드바는 읽기만 한다. |
| 어떤 세션이 열려 있었는지 | 사이드바가 자기 폴더에 저장한다. |

사이드바는 세션을 찾아 탭과 짝을 맞추고, 열려 있던 세션의 목록을 관리한다. 다시 열 때는 `claude --resume`이나 `codex resume`을 대신 입력하고, 대화를 이어 가는 일은 Claude Code와 Codex가 한다.

목록은 `~/Library/Application Support/Ghostty Sidebar/sessions/`에 있다.

| 파일 | 내용 |
|---|---|
| `claude.json` | 열려 있던 Claude 세션의 ID, 폴더, 제목 |
| `codex.json` | 열려 있던 Codex 세션의 ID, 폴더, 제목 |
| `closed.json` | 직접 닫은 세션, 닫은 시각과 함께 최근 7일, 최대 30개 |
| `history/claude/`, `history/codex/` | 이전 목록의 사본. 10분에 한 번까지 남기고 종류별 최근 10개를 보관한다. |

- 사이드바는 5초마다 `~/.claude/sessions/*.json`에서 실행 중인 Claude 세션을 찾는다.
- 실행 중인 세션이 바뀌면 목록을 다시 쓴다. 바뀌지 않아도 5분마다 제목과 브랜치를 갱신한다.
- 마지막 세션을 닫아 실행 중인 세션이 0개가 되어도 목록을 다시 쓴다. Ghostty 종료로 끝난 세션은 "비정상 종료"에 남으므로 목록에서 빠지지 않는다. 재부팅하면 사이드바도 함께 끝나므로 마지막 목록이 그대로 남는다.
- 탭 하나를 닫으면 직접 닫은 것으로 본다. 그 세션은 열린 세션 목록에서 빠지고 "최근에 닫음"으로 옮긴다.
- 5초 사이에 두 개 이상이 끝나면 비정상 종료로 본다. 그 세션들은 열린 세션 목록에 남고 "비정상 종료"에 나온다.

"닫힌 세션" 그룹은 처음에 접혀 있고, 펼치면 두 묶음으로 나뉜다.

| 묶음 | 내용 | 일괄 동작 |
|---|---|---|
| 비정상 종료 | 재부팅, Ghostty 종료, 창 닫기로 한꺼번에 끝난 세션 | 모두 열기 |
| 최근에 닫음 | 직접 닫은 세션, 닫은 시각 순서 | 비우기 (대화 기록은 지우지 않음) |

- 항목을 누르면 다시 열고, 마우스를 올리면 나오는 ×로 목록에서 뺀다.
- 대화 기록 파일이 지워진 세션은 한 시간마다 확인해 목록에서 뺀다.
- 사이드바가 실행 중일 때 닫힌 세션만 기록한다. 사이드바를 설치하기 전에 닫은 세션은 나오지 않는다.
- 예전 버전은 목록을 `~/.claude/session-restore/`와 `~/.codex/session-restore/`에 썼다. 새 폴더에 목록이 없으면 처음 실행할 때 한 번 옮겨 온다.

### Codex 세션

Codex는 Claude Code와 달리 실행 중인 세션을 알려 주는 파일이 없다. 사이드바는 다음 순서로 세션을 찾는다.

1. 터미널을 가진 `codex` 프로세스를 찾고, 작업 폴더와 시작 시각을 읽는다. `codex app-server` 같은 백그라운드 프로세스는 터미널이 없으므로 빠진다.
2. `~/.codex/sessions/<연>/<월>/<일>/rollout-<시작 시각>-<ID>.jsonl`에서 같은 폴더의 기록 파일을 찾는다. 새 세션은 프로세스가 시작한 직후에 기록 파일을 만들므로, 시작 시각 이후에 처음 만들어진 파일을 고른다.
3. 사이드바가 `codex resume <ID>`로 다시 연 세션은 사이드바가 그 ID를 기억해 둔다. Codex는 실행 인자를 감추고, 다시 연 세션은 다음 질문 전까지 기록 파일을 고치지 않기 때문이다.
4. 다른 방법으로 다시 연 세션은 대화를 이어 가서 기록 파일이 바뀌면 찾는다.

- 세션 이름은 `~/.codex/session_index.jsonl`의 `thread_name`을 쓴다.
- 아직 질문을 한 번도 하지 않은 Codex 세션은 기록 파일이 없으므로 저장하지 않는다. 다시 열 내용도 없다.
- 서브에이전트 기록 파일은 세션 목록에서 뺀다.

## 비용 계산

비용은 Claude Code 전사 파일(`~/.claude/projects/<폴더>/<세션>.jsonl`)의 토큰 사용량에 Claude API 정가를 곱해 계산한다.

- Claude 구독으로 쓰면 토큰별 요금이 청구되지 않는다. 이때 숫자는 API로 썼을 때의 환산 금액이다.
- 응답 하나는 블록마다 같은 사용량이 여러 줄로 기록된다. 메시지 ID로 한 번만 센다.
- 서브에이전트 전사 파일(`<세션>/subagents/*.jsonl`)의 비용도 세션에 더한다.
- 캐시 쓰기는 5분 TTL이 입력 단가의 1.25배, 1시간 TTL이 2배다. fast 모드 응답은 2배로 계산한다.
- 가격표는 `Sources/GhosttyBridge/Sessions/Pricing.swift`에 있다. 모르는 모델은 비용을 0으로 센다.

탭과 세션은 제목으로 연결한다. Claude Code는 터미널 제목을 전사 파일의 AI 제목과 같게 설정하므로, 같은 제목의 세션을 찾고 같은 제목이 여럿이면 작업 폴더로 고른다.

## 개발

```
swift build
swift test
.build/debug/ghostty-sidebar --mock     # 가짜 데이터로 화면만 확인
.build/debug/ghostty-probe list         # Ghostty 탭 목록
.build/debug/ghostty-probe sessions     # Claude 세션, 비용, 탭 연결 결과, Codex 세션
.build/debug/ghostty-probe open <폴더> 'echo hi\n'
```

| 대상 | 내용 |
|---|---|
| `GhosttyBridge` | Ghostty AppleScript 연결, 제목 해석, 창 배치 계산, Claude 세션 파일 읽기. UI가 없어 단위 테스트 대상이다. |
| `GhosttySidebar` | SwiftUI 사이드바와 메뉴 막대 앱 |
| `GhosttyProbe` | 연결 상태를 터미널에서 확인하는 도구 |

디버그 실행 파일은 `ghostty-sidebar` 설정 영역을 쓰고, 설치한 앱은 `dev.local.ghostty-sidebar` 설정 영역을 쓴다. 두 설정은 서로 섞이지 않는다.

## 문서

- [docs/history.md](docs/history.md): 단계별 변경 이력과 검증 결과
- [docs/design.md](docs/design.md): 구조, 설계 결정, 저장 파일, 설정 키, 한계
