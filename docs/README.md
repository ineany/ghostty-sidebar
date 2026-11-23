# Ghostty Sidebar 문서

이 폴더는 Ghostty Sidebar를 만든 과정과 구조를 기록한다.
사용법과 설치 방법은 저장소 최상위의 [README](../README.md)에 있다.

| 문서 | 내용 |
|---|---|
| [변경 이력](history.md) | 2026-11-15부터 진행한 단계별 요청, 변경 내용, 검증 결과, 발견한 문제 |
| [구조와 설계 결정](design.md) | 모듈 구성, 데이터 흐름, 주요 결정과 그 이유, 저장 파일, 한계 |

## 한눈에 보기

- 기본 Ghostty를 고치지 않는다. Ghostty 옆에 세로 탭 목록을 띄우는 별도 macOS 앱이다.
- Ghostty는 AppleScript로 제어하고, 창 이동은 macOS 손쉬운 사용 API로 한다.
- Claude Code와 Codex 세션을 찾아 탭과 짝을 맞춘다. 열린 세션의 목록을 관리하고 닫힌 세션을 다시 연다.
- Claude 세션마다 API 환산 비용을 보여 준다.
- 탭을 창별로 보거나 프로젝트별로 묶어 볼 수 있다.
- `scripts/make-dmg.sh`로 DMG 배포본을 만든다.

| 항목 | 값 |
|---|---|
| 저장소 | https://github.com/ineany/ghostty-sidebar |
| 언어와 도구 | Swift 6.3, SwiftPM, SwiftUI와 AppKit, macOS 14 이상 |
| 대상 Ghostty | 1.3.1 |
| 소스 규모 | Swift와 스크립트 약 5,700줄 |
| 테스트 | XCTest 76개 |
| 커밋 | 첫 커밋 하나 (2026-11-23 공개) |
