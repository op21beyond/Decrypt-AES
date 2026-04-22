# 8장 — 버그를 찾고 고치다

---

## 버그는 반드시 온다

어떤 설계든 첫 번째 버전에 버그가 없을 수 없다.  
AI가 만든 코드도 마찬가지다. 중요한 것은 버그가 있느냐 없느냐가 아니라,  
**버그를 얼마나 빠르게 찾고, 얼마나 정확하게 고치는가**다.

좋은 소식은 버그가 나온다는 사실 자체가 실패를 뜻하지는 않는다는 점이다.  
나쁜 소식은, 그렇다고 버그가 스스로 사라지지도 않는다는 점이다. 결국 누군가는 파형을 봐야 한다.

4월 13일 저녁~14일 오전, 두 번의 커밋에서 세 가지 버그가 발견되고 수정됐다.

```
dfed89d  update  ← SRAM 모델 추가, sync_fifo 수정, 합성 스크립트 추가
dfff9c6  update  ← CRC 초기화 버그, AXI Manager 수정
```

각 버그를 순서대로 살펴보자.

---

## 버그 1: sync_fifo의 이중 구동(Double Driver)

### 증상

합성 툴을 돌리자마자 경고가 나왔다.

```
Warning: Multiple drivers on net 'wr_ptr'
  1. Always block at sync_fifo.v:45
  2. Always block at sync_fifo.v:67
```

시뮬레이션에서는 동작하는 것처럼 보였지만, 합성에서는 구조적 오류다.  
이런 종류의 버그는 특히 얄밉다. 겉으로는 멀쩡한데, 정작 생산 라인 입구에서 출입 금지를 당한다.

### 원인

초기 `sync_fifo.v`에서 `wr_ptr`을 두 개의 `always` 블록이 동시에 구동하고 있었다.

```verilog
// Before (버그 있는 코드)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) wr_ptr <= 0;           // 리셋
end

always @(posedge clk) begin
    if (wr_en && !full) wr_ptr <= wr_ptr + 1;  // 쓰기
end
```

이것은 Verilog에서 동일한 reg를 두 개의 절차 블록이 구동하는 고전적인 실수다.  
시뮬레이션에서는 `rst_n=1`이면 첫 번째 블록이 아무것도 하지 않아 우연히 동작하지만, 합성에서는 멀티플 드라이버가 되어 버린다.

### 수정

```verilog
// After (수정된 코드)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= 0;   // 리셋과 쓰기를 하나의 블록으로
    end else begin
        if (wr_en && !full)
            wr_ptr <= wr_ptr + 1;
    end
end
```

### AI와의 수정 과정

```
# 사용자 → Claude
sync_fifo.v에서 합성 툴이 wr_ptr 이중 구동 경고를 내고 있어.
두 개의 always 블록이 동일한 reg를 구동하는 문제야.
수정해줘.
```

```
# Claude 수정 후 메시지
wr_ptr을 단일 always 블록에서 관리하도록 수정했습니다.
async reset은 always @(posedge clk or negedge rst_n) 블록 안에서
if (!rst_n) 분기로 처리하는 것이 표준 패턴입니다.
rd_ptr, count도 동일한 패턴으로 되어 있는지 확인해보는 것이 좋겠습니다.
```

> [IMG] **[그림 8-1]** *Claude Code에서 sync_fifo.v 수정 사항이 diff 뷰로 표시되는 화면*  
> *삭제된 라인은 빨간색, 추가된 라인은 초록색으로 표시되고, Approve 버튼이 있다*

이 과정에서 AI가 `rd_ptr`, `count`도 같은 패턴 문제가 있을 수 있다고 미리 알려준 것에 주목하자.  
AI는 단순히 요청한 부분만 고치는 것이 아니라, 같은 패턴의 다른 문제도 찾아낸다.  
이럴 때 AI는 "코드를 써주는 도구"라기보다 "같이 냄새를 맡아주는 리뷰어"에 더 가깝다.

---

## 버그 2: SRAM 포트 인터페이스 불일치

### 증상

테스트벤치를 연결하려는데 FIFO의 SRAM 포트가 연결되지 않았다.  
초기 `sync_fifo.v`에는 외부 SRAM 포트가 없었다 — 내부에 `reg` 배열을 사용했다.

```verilog
// Before (reg 배열 사용)
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];  // 내부 메모리
```

ASIC 환경에서는 이것이 문제다.  
컴파일드 SRAM을 써야 하는데, 내부 reg 배열은 플립플롭으로 합성된다.  
MBIST 삽입도 불가능하다.  
시뮬레이션 단계에서는 편하지만, 실제 칩 관점에서는 "지금은 좋은데 나중엔 곤란한" 전형적인 선택이다.

### 해결 방향

**사용자 →**
```
sync_fifo.v를 수정해서 외부 SRAM 인터페이스를 추가해줘.

ASIC 환경에서 컴파일드 SRAM을 쓰려면 FIFO 컨트롤러와 메모리를 분리해야 해.
sync_fifo는 주소/데이터/enable 신호만 외부로 내보내고,
실제 메모리(sram_2p_32x64.v 등)는 aes_decrypt_engine.v에서 별도 인스턴스로 연결.

이 구조로 변경하고, aes_decrypt_mem_top.v에 모든 SRAM을 모아서 MBIST 경계를 만들어줘.
```

이 수정 이후 구조가 바뀌었다:

```
aes_decrypt_engine.v
├── aes_decrypt_input_ctrl.v
│   └── sync_fifo (cipher_fifo, 컨트롤러만)
│       ↕ SRAM 포트
└── aes_decrypt_mem_top.v  ← SRAM 집합체 (새로 추가)
    ├── sram_2p_32x64 (cipher FIFO storage)
    └── sram_2p_32x72 (output FIFO storage)
```

아키텍처 문서(`doc/AES-Decrypt-IP-Architecture-Description.md`)에 이 변경이 반영됐다:

```markdown
## 9. Known Issues / Design Notes

2. SRAM read latency: The sram_2p_32x* behavioral models use asynchronous
   combinational read to match show-ahead FIFO behavior. If the foundry SRAM
   provides only synchronous read, the sync_fifo controller must be updated
   to add a 1-cycle output pipeline register.
```

---

## 버그 3: CRC 엔진 초기화 타이밍

### 증상

CRC 오류 테스트 케이스를 만들었는데, CRC 정상 케이스에서도 오류가 발생했다.  
Descriptor를 여러 개 연속으로 처리할 때 두 번째 Descriptor부터 CRC 값이 틀렸다.

### 원인

CRC 엔진의 `crc_init` 신호가 새 Descriptor 처리 시작 시 1클록 늦게 도착했다.

```verilog
// Before: ctrl.v에서 crc_init 타이밍
TOP_WB_INPROG: begin
    wb_start <= 1'b1;
    // ...
    crc_init <= 1'b1;  // ← 이 상태에서 crc_init
end

TOP_JOB_RUN: begin
    input_job_start <= 1'b1;
    crc_init <= 1'b0;  // ← JOB_RUN 진입 시 해제
end
```

문제는 `input_ctrl`이 `JOB_RUN` 상태 진입 직후 첫 ciphertext beat를 CRC 엔진에 보낼 수 있는데, `crc_init`이 이미 0이 되어 이전 Descriptor의 CRC 값이 남아있을 수 있었다.

### 수정

```verilog
// After: crc_init을 JOB_RUN 시작 직전에 1클록 asserted 상태로 보장
TOP_WB_INPROG: begin
    wb_start  <= 1'b1;
    crc_init  <= 1'b1;  // CRC 초기화 시작
    // input_job_start는 아직 내보내지 않음
end

TOP_JOB_RUN: begin
    // 이 상태 진입 시에도 crc_init=1이 한 클록 보장됨
    input_job_start <= 1'b1;  // 이 사이클에 crc_init은 아직 1
    crc_init        <= 1'b0;  // 다음 클록부터 0
end
```

이 타이밍 문제는 시뮬레이션 없이는 발견하기 어려운 버그다.  
테스트벤치에서 "여러 Descriptor 연속 처리" 케이스를 만들었기 때문에 발견할 수 있었다.  
단일 케이스만 돌렸다면 꽤 오래 숨어 있었을 가능성이 높다. 버그는 늘 가장 덜 귀찮은 테스트를 좋아한다.

---

## AI와 함께 버그를 디버깅하는 방법

버그를 발견했을 때 AI에게 가장 효과적으로 전달하는 방법:

### 방법 1: 증상 + 의심 범위 전달

```
CRC 테스트에서 두 번째 Descriptor의 CRC가 틀려.
첫 번째는 맞고, 두 번째부터 틀린다는 건 초기화 문제일 것 같아.
crc_init 신호의 타이밍을 aes_decrypt_ctrl.v에서 확인해줘.
```

### 방법 2: 시뮬레이션 로그 전달

```
시뮬레이션에서 이런 로그가 나왔어:

[TEST] multi_descriptor_test
[PASS] Descriptor 0: CRC OK
[FAIL] Descriptor 1: computed CRC=0xDEADBEEF, expected=0x12345678

CRC가 초기화되지 않고 누적되는 것 같아.
crc32_engine.v와 ctrl.v에서 crc_init 관련 코드를 보여줘.
```

### 방법 3: diff를 직접 제시해서 검토 요청

```
이 diff를 검토해줘. 의도한 방향이 맞는지 확인해줘.

--- a/design/rtl/aes_decrypt_ctrl.v
+++ b/design/rtl/aes_decrypt_ctrl.v
@@ -142,7 +142,6 @@ TOP_WB_INPROG: begin
     wb_start  <= 1'b1;
     crc_init  <= 1'b1;
-    input_job_start <= 1'b1;  // 제거: 한 클록 늦춤
 end
 TOP_JOB_RUN: begin
+    input_job_start <= 1'b1;  // 여기서 시작: crc_init=1인 상태에서
```

---

## 버그 수정이 가르쳐 주는 것

세 가지 버그의 공통점:
1. **구조적 오류** (이중 구동) — 문법/구조 레벨
2. **아키텍처 불일치** (SRAM 인터페이스) — 설계 의도 레벨
3. **타이밍 오류** (CRC 초기화) — 동작 레벨

AI가 생성한 코드에서 발생한 버그의 성격은 사람이 짜는 코드와 크게 다르지 않다.  
차이가 있다면, AI는 구조적 오류보다 타이밍/의도 불일치 버그를 더 자주 낸다.  
이것은 AI가 **문법보다 의미를 처리하는 데 더 어려움을 겪기 때문**이다.  
겉보기엔 그럴듯한데, 두세 클록 뒤에 마음이 틀어지는 식의 실수다.

그리고 AI는 버그를 고치는 것도 빠르다.  
문제를 명확하게 설명하면, 올바른 수정안을 수분 안에 제시한다.

---

## commit dfed89d — 이날 추가된 것들

버그 수정 외에도 이 커밋에서 중요한 것들이 추가됐다.

```
design/syn/constraints.sdc   ← 200MHz 타이밍 제약 (SDC)
design/syn/run_dc.tcl        ← Synopsys DC 합성 스크립트
doc/AES-Decrypt-IP-Architecture-Description.md ← 아키텍처 문서
doc/compiled_memory_list.txt ← MBIST용 SRAM 목록
```

합성 스크립트도 AI가 만들었다. 템플릿 수준이지만 구조는 완전하다.

```tcl
# design/syn/run_dc.tcl (핵심 부분)
# THROUGHPUT_TARGET: 200MHz 타이밍 제약
set CLK_PERIOD_NS 5.0   ;# 200 MHz = 5ns period
create_clock -period $CLK_PERIOD_NS [get_ports clk]

# 합성 타겟 (PDK 경로는 실제 환경에 맞게 수정 필요)
# set_attribute [get_lib *] default_threshold_voltage_group LVT
```

---

*다음 장: 9장 — 오픈소스 CI로 자동화하다*
