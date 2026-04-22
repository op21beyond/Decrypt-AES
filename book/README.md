# 「AI한테 칩 설계 시켜봤다」
## 하드웨어 엔지니어를 위한 바이브코딩 실전 입문

---

> **저자:** SSVD SoC Team  
> **대상 독자:** SoC·IP 개발 경험이 있고, AI를 이용한 개발 방식이 아직 낯선 하드웨어 엔지니어  
> **개발 환경:** Windows 11 + VSCode + Claude Code Extension (Claude Sonnet)  
> **개발 기간:** 2026년 4월 12일 ~ 14일 (3일)

---

## 이 책에서 만드는 것

AES-128 CTR 모드 복호화 하드웨어 IP — **AES Decryption Engine**

- Memory-to-memory 방식의 DMA 가속기
- AXI4 64-bit Manager + AXI4-Lite Subordinate 인터페이스
- Descriptor 기반 링 버퍼 커맨드 큐 (최대 1024개)
- CRC-32 무결성 검증 (IEEE 802.3 / Castagnoli 선택)
- 목표 처리량: 200 Mbps

**완성된 결과물:**
- IP 구현 사양서 (Markdown)
- Verilog RTL — 9개 모듈
- 호스트 C 소프트웨어 — 레퍼런스 구현 + IP 드라이버
- 시뮬레이션 테스트벤치 (NCVerilog / Verilator)
- 합성 스크립트 (Synopsys DC)
- GitHub Actions CI 파이프라인

---

## 목차

| 장 | 제목 | 핵심 내용 |
|---|---|---|
| 프롤로그 | [바이브코딩이 하드웨어 엔지니어에게 오다](ch00_prologue.md) | 바이브코딩이란, 왜 지금인가 |
| 1장 | [첫 번째 프롬프트 — 거친 아이디어를 던지다](ch01_first_prompt.md) | original-prompt.md, 첫 대화 시작 |
| 2장 | [AI가 사양서를 쓰다](ch02_spec_writing.md) | project-instructions.md 구조화, 사양서 완성 |
| 3장 | [결정적 전환 — 설계까지 맡겨보기로 하다](ch03_pivot.md) | 피벗 결정, 설계 전략 |
| 4장 | [프로젝트의 골격을 세우다](ch04_project_structure.md) | 폴더 구조, 룰, AI 협업 규약 |
| 5장 | [RTL을 바이브코딩하다](ch05_rtl_vibe_coding.md) | 9개 모듈, 파이프라인 아키텍처 |
| 6장 | [레퍼런스 소프트웨어를 만들다](ch06_host_software.md) | Pure C AES, IP 드라이버 |
| 7장 | [검증 환경을 구축하다](ch07_testbench.md) | Fake CPU, Fake Memory, 시뮬레이션 |
| 8장 | [버그를 찾고 고치다](ch08_bug_fixing.md) | sync_fifo, CRC, AXI 수정 사이클 |
| 9장 | [오픈소스 CI로 자동화하다](ch09_verilator_ci.md) | Verilator + GitHub Actions |
| 10장 | [다른 AI를 리뷰어로 부르다](ch10_codex_review.md) | Codex 코드 리뷰, 완성도 향상 |
| 에필로그 | [AI 동료와 일한다는 것](ch11_epilogue.md) | 한계, 가능성, 다음 단계 |

---

## 이 책을 읽는 법

각 장은 독립적으로 읽을 수 있지만, **1장 → 4장**은 순서대로 읽기를 권장한다.  
바이브코딩의 흐름과 AI와의 대화 방식을 먼저 체감한 뒤, 관심 있는 기술 챕터로 넘어가면 된다.

코드 스니펫은 핵심 부분만 발췌했다. 전체 코드는 프로젝트 저장소를 참고하라.

```
Decrypt-AES/
├── spec/       ← IP 사양서
├── design/rtl/ ← Verilog RTL
├── design/tb/  ← 시뮬레이션 테스트벤치
├── host_software/ ← C 드라이버 & 테스트
└── book/       ← 이 책
```
