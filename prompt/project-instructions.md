# AES Decrypt IP — 프로젝트 지시 및 확정 사양

## 프로젝트 폴더 구조

| 폴더/파일 | 내용 |
|---|---|
| `prompt/` | 이 문서. 프로젝트 전체 지시 및 확정 결정사항 저장 |
| `doc/` | 프로젝트 결과물(사양서 제외) 설명 문서 |
| `spec/` | 사양 문서 결과물 |
| `design/` | Verilog — DUT, Testbench, Task, Test data |
| `host_software/` | Host C code — Pure C 버전, DUT 사용 버전, Test data |
| `README.md` | 과정 설명, 폴더 구조, 사용방법, 주요 changelog 및 버전 |

---

## 기타 룰

- 어느 하나에 수정이 있을 경우 프로젝트 내 모든 코드, 문서 등이 일관성을 유지하도록 함께 반영할 것.
- 문서에서 회사명은 **SSVD**, 필요 시 팀명은 **SoC team**, IP 개발 주체는 **Company**.
- 문서 내 Manager(= M a s t e r), Subordinate(= S l a v e) 표기. 설명 문장에서 불가피하게 해당 단어를 사용해야 할 경우(예: AXI 표준 용어 인용 등) 반드시 **M a s t e r**, **S l a v e** 처럼 글자 사이에 공백을 두어 표기.
- 모든 작성물은 **영어**로 작성.

---

## IP 개요

칩 내 IP 개발자가 설계할 **AES Decryption Hardware Engine** 개발 사양.

- **동작 방식:** Memory-to-Memory
- **버스 인터페이스:**
  - **Manager(AXI4):** 메모리 버스 read/write (descriptor, input buffer, output buffer)
  - **Subordinate(AXI4-Lite):** 레지스터 read/write (host SW 제어 인터페이스)
- **인터럽트 출력:** 있음 (단일 인터럽트 라인, active-high level — 클리어 전까지 High 유지)
- **AES 알고리즘:** AES-128 CTR 체인 모드 복호화

---

## 동작 상세

### 상태 머신

```
STOP → (start=1 or resume=1 write) → ACTIVE → (last descriptor 완료) → STOP
ACTIVE → (interrupt 발생, SW 처리 대기) → PAUSE → (resume=1 write) → ACTIVE
ACTIVE / PAUSE → (immediate_stop=1 write) → STOP
```

- IP 초기 상태: **STOP**
- STOP 상태에서 상태 레지스터에 STOP 상태임이 표시되어 있어야 함.
- Host SW가 제어 레지스터에 `start` 또는 `resume`을 1로 쓰면 상태 레지스터를 **ACTIVE**로 전환하고, 명령 버퍼(circular buffer)에서 유효한 Descriptor를 읽어 명령 처리 시작.
- 처리 완료 시: 메모리의 해당 Descriptor 상태 필드에 **완료** 기록, Descriptor의 `valid` 플래그 클리어.
- Descriptor의 `interrupt` 필드 = 1이면 인터럽트 발생 → **PAUSE** 상태 진입 → SW가 `resume=1` 쓸 때까지 대기.
- `resume=1` 수신 시: resume 비트 클리어, 명령 버퍼의 다음 Descriptor 처리.
- Descriptor의 `interrupt` 필드 = 0이면 완료 후 인터럽트 없이 즉시 다음 Descriptor 처리.
- Descriptor의 `last` 필드 = 1이면 해당 Descriptor 처리 완료 후 **STOP** 상태 진입 (`interrupt` 필드와 무관하게 `interrupt` 필드에 따른 인터럽트 동작 먼저 수행 후 STOP).
- STOP/PAUSE 상태에서 Host는 레지스터 설정 변경 가능.
- ACTIVE/PAUSE 상태에서 Host는 `immediate_stop=1`을 제어 레지스터에 써서 즉시 STOP 상태로 전환 가능.

### Descriptor가 유효하지 않은 경우 (valid=0)

- `interval` 레지스터에 설정된 사이클 수만큼 대기 후 해당 Descriptor를 재시도.

### AXI 버스 에러 처리

AXI Manager 인터페이스에서 버스 에러(RRESP 또는 BRESP가 OKAY 이외의 값)가 발생하면:

1. 해당 Descriptor의 상태 필드에 버스 에러 발생을 기록 (읽기 에러/쓰기 에러 구분).
2. IP 상태 레지스터(STATUS)의 버스 에러 플래그를 Set — Host가 나중에 W1C로 클리어.
3. 버스 에러가 발생한 Descriptor 및 이후 Descriptor의 AES 처리를 중단.
4. 버스 에러 발생 이전에 이미 처리가 완료된 Descriptor는 그대로 유지.
5. 현재 진행 중인 모든 outstanding AXI transaction이 완료되면 **STOP** 상태로 전환.
6. `IRQ_ENABLE`의 **IRQ_ON_BUS_ERROR** 비트가 1로 설정되어 있으면 인터럽트 발생.

> Subordinate(AXI4-Lite 레지스터) 인터페이스에서는 버스 에러를 출력하지 않음 (BRESP/RRESP는 항상 OKAY).

---

## Descriptor 구조

### 위치

- Host SW가 메모리에 구성하는 **Circular Buffer**.
- 링 버퍼 Base Address 및 최대 Descriptor 수: IP 레지스터로 설정 (**최대 1024개**).

### Descriptor 레이아웃 (32바이트)

Descriptor에는 제어 정보와 버퍼 포인터/크기 정보만 포함. AES 처리용 데이터(AES Header, 암호화 데이터, CRC)는 **입력 버퍼**에 저장.

| Offset | 크기 | 필드 |
|---|---|---|
| 0x00 | 4B | Header Word (valid, interrupt, last, state 등 제어/상태 필드) |
| 0x04 | 4B | 입력 버퍼 시작 주소 (32-bit) |
| 0x08 | 4B | 출력 버퍼 시작 주소 (32-bit) |
| 0x0C | 4B | 유효 입력 데이터 크기(24-bit, byte) + 마지막 패딩 크기(8-bit, byte) |
| 0x10 | 4B | 유효 출력 데이터 크기(24-bit, byte) + 출력 패딩 크기(8-bit, byte) |
| 0x14 | 12B | Reserved (write 0) |

**Header Word 필드:**

| 필드 | 비트 폭 | 설명 |
|---|---|---|
| `valid` | 1 | 1 = Descriptor 유효 |
| `state` | (TBD) | IP가 처리 완료 후 기록하는 상태 (완료, CRC 오류 등) |
| `interrupt` | 1 | 1 = 처리 완료 후 인터럽트 발생 및 PAUSE |
| `last` | 1 | 1 = 이 Descriptor 처리 후 STOP |

- `valid`, `state` 등 개별적으로 업데이트 가능한 필드는 AXI Write Strobe로 byte 단위 업데이트 가능하도록 byte 단위로 할당
- AES Key는 Descriptor가 아닌 **IP 레지스터**에 저장 (Host SW가 미리 write)
- 데이터 크기: **byte-aligned** (bit 단위 이하는 없음)

### 입력 버퍼 레이아웃

입력 버퍼에는 다음 순서로 데이터가 배치됨:

| 순서 | 크기 | 내용 |
|---|---|---|
| 1 | 16B | AES Header: Nonce/IV (96-bit) + Initial Counter (32-bit) |
| 2 | IN_DATA_SIZE bytes | 암호화된 페이로드 (ciphertext) |
| 3 | IN_PAD_SIZE bytes | 패딩 (0 가능, CRC 계산 대상 아님) |
| 4 | 4B | CRC-32 값 (Encrypted payload에 대한 CRC; AES Header 제외) |

- CRC 계산 범위: **Encrypted payload(IN_DATA_SIZE bytes)만**. AES Header(16B) 및 패딩 제외. CRC와 AES 복호화는 병렬로 실행.
- CRC 오류 발생 시: Descriptor 상태 필드에 **CRC 오류** 기록 후 처리 완료 처리 (정상 완료 아님을 명시).

---

## AES 처리

- **알고리즘:** AES-128 CTR Mode
- **키 저장:** IP 레지스터 (128-bit, host SW가 사전 write)
- **IV/초기 카운터:** 입력 버퍼의 AES Header 첫 16바이트에서 읽음 (128-bit)
- **CRC 알고리즘:** CRC-32/IEEE 802.3 또는 CRC-32C — **IP 레지스터로 선택**

---

## 버스 인터페이스 (AXI4 Manager)

- **데이터 폭:** 64-bit
- **필수가 아닌 신호 (USER, QOS 등):** 미사용 또는 잠재적 문제 없는 최소값으로 고정
- **AxCACHE, AxPROT:** Descriptor read / Input buffer read / Output buffer write 각각 **IP 레지스터로 설정 가능**
- **Outstanding Read Transactions:** 최대 16개, **IP 레지스터로 16 이하로 설정 가능**
- **Outstanding Write Transactions:** 최대 16개, **IP 레지스터로 16 이하로 설정 가능**

---

## 성능 요구사항

> ⚠️ **[THROUGHPUT REQUIREMENT — 검토 및 수정 필요]**
> **목표 처리량: 200 Mbps**
> (향후 변경 시 반드시 spec, design, README 등 전체 문서 동기화 업데이트 필요)

---

## IP 설계 요구사항 (Verilog)

1. 사양서대로 하드웨어를 Verilog로 구현.
2. **고성능 파이프라인 구조:**
   - Descriptor의 고정 크기 부분은 한 번에 읽어 해석 (read latency 중첩 방지).
   - 전체 데이터 크기 등 가변 크기 부분은 Descriptor에서 확인되는 즉시 IP 내부 입력 버퍼로 미리 read 시작 → AES core starvation 방지.
   - 입력 버퍼의 빈공간이 없는데 버스에 너무 많은 read request를 보내 다른 IP에게 병목을 일으키는 설계 금지.
3. 합성 가능, ASIC 환경에서 문제 없어야 함.
4. Divider, Wide-bit multiplier 사용 금지 (STA 타이밍 문제 방지).
5. 생산 가능한 수준의 완성도.
6. 헤더는 일관된 양식 적용, 코드 내 주석은 적절하게(과하지 않게) 추가.
7. 사양서에 명시된 내용과 관련된 부분에 **옵션으로 on/off 가능한 (`define)** SystemVerilog Assertion 및 Coverage 코드 추가.

---

## Host Software 요구사항 (C 코드)

1. 테스트용 AES encrypted 스트림 데이터, decrypted 스트림 데이터, Descriptors 포함.
2. Pure software 버전 (AES decrypt 소프트웨어 구현).
3. Reference IP 사용 버전 (IP 레지스터 제어 포함).
4. 특정 Host CPU 가정 없이 **generic**하게 코딩.

---

## 시뮬레이션 검증 환경 (Verilog)

1. DUT 외에 검증에 필요한 구성요소 모두 포함.
2. Host software C 코드 대신 **Verilog read/write/verify task** 활용.
3. 구성:
   - **Fake Host CPU:** File reader + AXI4 Manager + Interrupt 입력 핸들러
   - **Fake Memory:** Simple AXI4 Subordinate (`readmemh` 초기화)
   - **DUT:** AES Decrypt IP
   - **Simple Bus:** 상기 구성요소 연결
4. 시뮬레이터: **NCVerilog**, 덤프 포맷: **FSDB**

---

## 문서 요구사항

- 전문적이되 친절하고 장황하거나 혼란스럽지 않을 것.
- 사양서와 다른 결과물 간 **일관성** 유지.
