# 2장 — AI가 사양서를 쓰다

---

## 사양서가 만들어지는 방식이 달라졌다

전통적인 IP 개발에서 사양서는 가장 시간이 걸리는 문서다.  
요구사항을 수집하고, 인터페이스를 정의하고, 레지스터 맵을 그리고, 동작 다이어그램을 그리고, 용어를 통일하고, 다시 처음으로 돌아가 빠진 항목을 메우고…  
경험 많은 엔지니어도 며칠에서 일주일이 걸린다. 그리고 그 며칠은 대체로 생각보다 빨리 지나간다.

이 프로젝트에서는 달랐다. AI가 초안을 만드는 데 걸린 시간은 **수 분**이었다.  
문서의 품질과는 별개로, 이 속도 자체가 주는 심리적 이점이 크다. "아직 아무것도 없다"가 아니라 "이제부터 고치면 된다"가 되기 때문이다.

물론 초안이 곧 최종본은 아니다. 그러나 **빈 화면 앞에서 시작하지 않아도 된다**는 것은 완전히 다른 경험이다.

---

## AI가 만들어온 것

Claude가 생성한 사양서(`spec/AES-Decrypt-IP-Specification.md`)의 구조를 보면, 전문적인 IP 사양서의 형식을 따르고 있다.

```
1. Introduction        ← 목적, 범위, 대상 독자, 참조 문서
2. Terminology         ← 용어 정의 (Master→Manager, Slave→Subordinate)
3. System Overview     ← 블록 다이어그램, 주요 기능
4. Interface Signals   ← AXI4 Manager / AXI4-Lite Subordinate / IRQ 전체 핀
5. Register Map        ← 17개 레지스터, 비트 단위 정의
6. Descriptor Layout   ← 32바이트 레이아웃, 입력 버퍼 구조
7. Operational State Machine ← STOP / ACTIVE / PAUSE 전환 규칙
8. AES Processing      ← CTR 모드 동작, 키 스케줄
9. CRC Processing      ← 두 알고리즘 파라미터, 에러 처리
10. Interrupt Handling ← 타이밍 다이어그램 포함
11. Performance Requirements ← 200 Mbps 근거와 설계 제약
12. Bus Interface Specification ← AXI 세부 규칙
13. Electrical and Physical Constraints ← 합성 가능성 요구사항
14. Revision History
```

14개 섹션, 900라인 분량의 문서가 단번에 나왔다.  
문서를 다 읽기 전에 먼저 "잠깐, 이걸 정말 방금 만든 거야?"라는 반응이 나오는 종류의 결과물이었다.

---

## 사양서의 주요 결정 사항

AI가 채운 핵심 결정들을 확인하고 검토했다. 각 항목은 **확인(✓)** 또는 **수정(✎)** 으로 처리했다.  
중요한 건 감탄이 아니라 판정이다. "오, 잘 썼네"에서 끝내지 않고, 정말 이 선택이 맞는지 하나씩 도장을 찍어야 한다.

### 버스 인터페이스 ✓

```
AXI4 Manager: 64-bit 데이터폭, 32-bit 주소
AXI4-Lite Subordinate: 32-bit 데이터폭, 8-bit 주소 (256바이트 레지스터 공간)
```

64-bit 선택 이유는 사양서에 명시되어 있다.

> *"At 200 MHz with 64-bit AXI bus: peak AXI bandwidth = 1600 MB/s = 12.8 Gbps.  
> The 200 Mbps throughput requirement represents a light load on the bus."*

200 Mbps 목표 대비 버스 대역폭은 충분하고, 64-bit는 ASIC SoC에서 흔한 선택이다.

### 레지스터 맵 ✓ (일부 확인 필요)

AI가 설계한 레지스터 맵의 일부:

| Offset | Name | Access | 설명 |
|---|---|---|---|
| `0x00` | `CTRL` | W (self-clear) | START / RESUME / IMMEDIATE_STOP |
| `0x04` | `STATUS` | Mixed | STATE[1:0] RO, BUS_ERROR W1C |
| `0x10` | `CMD_BUF_ADDR` | R/W | Descriptor 링 버퍼 베이스 주소 |
| `0x20`~`0x2C` | `AES_KEY_[3:0]` | WO | AES-128 키 (읽기 시 0 반환) |
| `0x34` | `AXI_OUTSTAND` | R/W | Outstanding 트랜잭션 수 제한 |

AES 키 레지스터가 **WO(Write Only)** 로 설계된 것은 보안 관점에서 당연한 선택이다.  
CTRL 레지스터의 비트들이 **self-clearing pulse**로 설계된 것도 하드웨어 설계 관례에 맞다.

### Descriptor 레이아웃 ✓

```
Byte Offset  Size     Field
────────────────────────────────────────
0x00         4 B      Header Word (valid, interrupt, last, state)
0x04         4 B      Input Buffer Address
0x08         4 B      Output Buffer Address
0x0C         4 B      IN_DATA_SIZE[23:0] + IN_PAD_SIZE[7:0]
0x10         4 B      OUT_DATA_SIZE[23:0] + OUT_PAD_SIZE[7:0]
0x14        12 B      Reserved
────────────────────────────────────────
Total:       32 B
```

Header Word를 4개 바이트로 분할해서 AXI Write Strobe로 개별 업데이트 가능하게 한 것은 AI의 결정이었다. IP가 `valid=0`으로 클리어할 때 `state` 필드와 충돌하지 않도록 하기 위해서다. 실제 ASIC 설계에서도 자주 쓰이는 패턴이다.

### 입력 버퍼 레이아웃 — 중요한 결정 ✓

```
Input Buffer (at IN_ADDR)
──────────────────────────────────────────────────────
+0x00   16 B   AES Header (Nonce 96-bit + Initial Counter 32-bit)
+0x10    N B   Encrypted Payload (ciphertext)
+0x10+N  M B   Input Padding (버스 정렬용, CRC 계산 대상 아님)
+0x10+N+M 4 B  CRC-32 Value
──────────────────────────────────────────────────────
```

CRC를 **암호화된 데이터(ciphertext)** 에 대해 계산하는 설계는 중요한 결정이다.  
복호화 후의 plaintext에 CRC를 계산하면 AES 처리 완료 후에야 검증이 가능하다.  
Ciphertext에 CRC를 계산하면 **AES 복호화와 CRC 계산을 병렬로 실행**할 수 있다.  
AI가 이 트레이드오프를 이해하고 올바른 선택을 했다.

---

## 사양서를 다듬는 과정 — project-instructions.md

초안 사양서를 검토한 후, 저자는 AI와의 작업 규약을 정리한 별도 파일을 만들었다.  
`prompt/project-instructions.md` 가 그것이다. 쉽게 말해, AI와의 협업에서 자꾸 되풀이해 말해야 하는 것들을 한 장짜리 헌법으로 묶어 둔 셈이다.

이 파일은 두 가지 역할을 한다.

1. **확정된 결정 사항의 기록** — 이후 변경 시 여기를 먼저 업데이트
2. **AI에게 주는 지속적인 지시** — 매 대화마다 이 파일을 참조하도록

> [IMG] **[그림 2-1]** *project-instructions.md를 Claude Code에 컨텍스트로 추가하는 화면*  
> *파일을 드래그하거나 `@파일명` 으로 참조하면 AI가 해당 파일 내용을 읽는다*

---

## project-instructions.md의 구조

```markdown
## 프로젝트 폴더 구조
| 폴더/파일 | 내용 |
|---|---|
| prompt/   | 이 문서. 전체 지시 및 확정 결정사항 저장 |
| spec/     | 사양 문서 결과물 |
| design/   | Verilog — DUT, Testbench, Task, Test data |
| host_software/ | Host C code |

## 기타 룰
- 어느 하나에 수정이 있을 경우 프로젝트 내 모든 코드, 문서가 일관성을 유지하도록 반영
- 문서에서 회사명은 SSVD, 팀명은 SoC team
- Manager(=Master), Subordinate(=Slave) 표기
- 모든 작성물은 영어로 작성

## 확정 사양
- AXI4 64-bit Manager
- 목표 처리량: 200 Mbps
- CRC-32 dual (IEEE 802.3 / CRC-32C, 레지스터 선택)
- AES 키: IP 레지스터에 저장
- Descriptor 최대 1024개
```

---

## AI 협업에서 이 파일이 중요한 이유

Claude Code (그리고 대부분의 AI 코딩 어시스턴트)는 **대화 세션이 끊기면 이전 맥락을 잃는다**.  
새 세션을 시작할 때마다 "우리가 어디까지 했는지"를 다시 알려줘야 한다.

`project-instructions.md` 는 이 문제에 대한 해답이다.  
세션이 바뀔 때마다 같은 설명을 처음부터 다시 하는 일은 사람끼리도 지치는데, AI 상대로 하면 더 빨리 지친다.

```
# 새 세션 시작 시 첫 메시지 패턴
"prompt/project-instructions.md를 먼저 읽어줘.
이 프로젝트의 확정된 사양과 룰이 담겨 있어.
이후 작업은 이 파일을 기준으로 진행해."
```

AI는 이 파일을 읽고, 이전 결정 사항을 모두 파악한 뒤 작업을 시작한다.  
이렇게 하면 매번 컨텍스트를 다시 설명하는 시간을 절약할 수 있다.

---

## 완성된 사양서의 품질

완성된 사양서의 수준을 가늠하는 지표 몇 가지:

**아키텍처 일관성**  
레지스터 맵, Descriptor 레이아웃, 상태 머신이 서로 충돌하지 않는다.  
예를 들어, `interrupt=1`인 Descriptor가 완료되면 PAUSE 상태로 진입하고,  
`IRQ_STATUS.DESCRIPTOR_DONE` 비트가 set되며, `CTRL.RESUME=1`을 받아야 ACTIVE로 복귀한다.  
이 흐름이 레지스터 설명, 상태 머신 표, 인터럽트 핸들링 섹션에서 모두 일관되게 서술되어 있다.

**ASIC 고려사항 포함**  
```markdown
## 13. Electrical and Physical Constraints
- Dividers and wide multipliers are prohibited.
- No use of initial blocks except in testbench files.
- No combinational loops.
```
ASIC 합성 환경에서 문제가 되는 제약들이 명시되어 있다.

**성능 분석 포함**  
```markdown
At 200 MHz with 64-bit AXI bus:
peak AXI bandwidth = 200 MHz × 8 B = 1600 MB/s = 12.8 Gbps.
The 200 Mbps throughput requirement represents a light load on the bus.
```
200 Mbps가 왜 달성 가능한지 수치로 설명하고 있다.

---

## 사양서 작성이 끝난 시점의 판단

사양서를 검토하면서 한 가지 생각이 강하게 들었다.  
조금 위험하고, 그래서 더 매력적인 생각이었다.

> *"이 정도 사양서를 만들 수 있는 AI라면, RTL 코드도 충분히 만들 수 있지 않을까?"*

이것이 다음 장에서 다루는 **결정적 전환**으로 이어진다.

---

*다음 장: 3장 — 결정적 전환, 설계까지 맡겨보기로 하다*
