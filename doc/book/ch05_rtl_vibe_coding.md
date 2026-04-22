# 5장 — RTL을 바이브코딩하다

---

## 하루 만에 9개 모듈이 나왔다

2026년 4월 12일, initial 커밋에 포함된 RTL 파일 목록:

```
design/rtl/
├── inc/aes_decrypt_defs.vh
├── crypto/aes128_key_sched.v
├── crypto/aes128_enc_pipe.v
├── crypto/aes128_ctr_top.v
├── util/sync_fifo.v
├── util/crc32_engine.v
├── aes_decrypt_regfile.v
├── aes_decrypt_desc_fetch.v
├── aes_decrypt_input_ctrl.v
├── aes_decrypt_output_ctrl.v
├── aes_decrypt_writeback.v
├── aes_decrypt_axi_mgr.v
├── aes_decrypt_ctrl.v
└── aes_decrypt_engine.v
```

14개 파일. 전체 RTL 코드베이스가 한 번의 작업 세션에서 만들어졌다.  
이 문장을 처음 보면 약간 허풍처럼 들릴 수 있다. 그런데 실제로 해보면, "완성"의 의미를 엄격하게 잡더라도 놀랄 만큼 빠르다.  
물론 그 뒤에는 리뷰와 수정이 기다리고 있다. 버그는 늘 늦지 않게 도착한다.

---

## 아키텍처 결정: 어떻게 분해할 것인가

전체를 한 번에 요청하지 않았다. 먼저 아키텍처를 AI와 논의했다.

**사용자 →**
```
spec/AES-Decrypt-IP-Specification.md를 읽었지?
RTL 구현을 시작하기 전에, 어떤 모듈들로 나눌지 제안해줘.
AXI Manager 인터페이스를 어떻게 구현할지도 포함해서.
```

**Claude →**
```
사양서를 바탕으로 다음 모듈 구조를 제안합니다:

최상위 계층:
- aes_decrypt_engine.v   : 배선 전용 최상위

제어 계층:
- aes_decrypt_ctrl.v     : STOP/ACTIVE/PAUSE FSM + 파이프라인 오케스트레이션
- aes_decrypt_regfile.v  : AXI4-Lite 레지스터 파일

데이터 경로:
- aes_decrypt_desc_fetch.v  : Descriptor 읽기 (AXI read, ring buffer 관리)
- aes_decrypt_input_ctrl.v  : 입력 버퍼 읽기 (AES Header + ciphertext + padding + CRC)
- aes_decrypt_output_ctrl.v : 출력 버퍼 쓰기 (plaintext + padding)
- aes_decrypt_writeback.v   : Descriptor 상태 쓰기 (byte-strobe write)
- aes_decrypt_axi_mgr.v     : AXI4 Manager (2개 Read 포트 + 2개 Write 포트 중재)

암호화 코어:
- aes128_key_sched.v   : 키 스케줄 (순수 조합 논리)
- aes128_enc_pipe.v    : 10라운드 파이프라인 (10클록 지연)
- aes128_ctr_top.v     : CTR 모드 (카운터 블록 생성 + XOR)

유틸리티:
- crc32_engine.v       : CRC-32 (IEEE 802.3 / CRC-32C 선택 가능)
- sync_fifo.v          : 범용 동기 FIFO (SRAM 인터페이스)
- sram_2p_32x64.v      : SRAM 행동 모델 (cipher FIFO용)
- sram_2p_32x72.v      : SRAM 행동 모델 (output FIFO용)

AXI Manager는 4개의 독립 포트를 단일 AXI4 인터페이스로 중재합니다.
우선순위: RD0(Descriptor) > RD1(Input), WR0(Writeback) > WR1(Output)
```

이 구조 제안을 검토하고, 사양서와 대조해서 문제가 없다고 판단한 후 RTL 작성을 시작했다.  
중요한 점은 AI가 제안했고 사람이 승인했다는 흐름이다. "AI가 알아서 했다"보다 "AI가 여러 초안을 빠르게 내고 사람이 고른다"가 실제에 가깝다.

> [IMG] **[그림 5-1]** *Claude Code가 아키텍처 모듈 구조를 제안하는 대화 화면*  
> *텍스트 응답 아래에 "Create these files?" 라는 확인 프롬프트가 표시된다*

---

## 핵심 모듈 살펴보기

### 1. aes_decrypt_defs.vh — 프로젝트의 공통 언어

모든 모듈이 공유하는 파라미터와 상수를 여기에 정의했다.

```verilog
// Descriptor state codes — spec Table 6.3
`define DSTATE_NOT_PROCESSED  8'h00
`define DSTATE_OK             8'h01
`define DSTATE_CRC_ERR        8'h02
`define DSTATE_RD_ERR         8'h03
`define DSTATE_WR_ERR         8'h04
`define DSTATE_IN_PROGRESS    8'hFF

// Engine top-level states — spec Table 7.1
`define ENG_STOP    2'b00
`define ENG_ACTIVE  2'b01
`define ENG_PAUSE   2'b10
```

이 파일이 있으면 다른 파일들이 매직 넘버를 직접 쓰지 않아도 된다.  
사양서의 섹션 번호까지 주석으로 달아서 추적 가능하게 했다.  
나중에 코드를 읽을 때 "이 숫자가 왜 여기 있지?" 대신 "아, spec의 그 표에서 왔구나"라는 식으로 맥락이 이어진다.

---

### 2. AES 파이프라인 코어

AES-128 CTR 모드의 핵심은 10라운드 암호화 파이프라인이다.

```verilog
// aes128_enc_pipe.v — 핵심 구조
module aes128_enc_pipe (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_valid,
    input  wire [127:0]  in_block,     // 카운터 블록
    input  wire [1407:0] round_keys,   // 키 스케줄 (11 x 128-bit)
    output wire          out_valid,
    output wire [127:0]  out_block     // 암호화된 블록 (= keystream)
);
    // 10-stage pipeline: 각 스테이지가 AES 1라운드를 처리
    reg [127:0] stage [0:9];
    reg         valid_pipe [0:9];

    // Stage 0: AddRoundKey (Initial)
    // Stage 1-9: SubBytes + ShiftRows + MixColumns + AddRoundKey
    // Stage 10 (out): SubBytes + ShiftRows + AddRoundKey (Final)
```

10클록 지연의 완전 파이프라인 구조다. 매 클록마다 새로운 블록을 입력받을 수 있다.  
겉으로는 조용한 모듈이지만, 안에서는 상당히 부지런하다.  
200 Mbps 목표를 달성하려면 이 파이프라인이 끊임없이 채워져 있어야 한다. 결국 성능은 "코어가 얼마나 빠르냐"보다 "굶기지 않느냐"의 문제로 바뀐다.

CTR 모드에서는 AES **Encrypt** 함수를 복호화에도 동일하게 사용한다.

```
Decrypt: P_i = C_i XOR AES_Encrypt(Key, Counter_Block_i)
```

`aes128_ctr_top.v`가 이를 조율한다.

```verilog
// aes128_ctr_top.v — CTR 모드 핵심 로직 (간략화)
// Counter block = { Nonce[95:0], (InitialCounter + i) mod 2^32 }
always @(posedge clk) begin
    if (aes_job_start) begin
        ctr_value <= aes_initial_ctr;
    end else if (enc_in_valid && enc_in_ready) begin
        ctr_value <= ctr_value + 1'b1;  // 32-bit wrap
    end
end

// 10클록 지연된 ciphertext와 keystream을 XOR
assign plaintext = cipher_delay[9] XOR out_block;
```

---

### 3. 최상위 FSM — aes_decrypt_ctrl.v

이 모듈이 전체 파이프라인을 지휘한다.  
사양서의 7.3절 "Detailed State Transition Rules"가 코드로 변환된 것이다.

```verilog
// 내부 FSM 상태 (TOP 레벨)
localparam TOP_STOP        = 4'd0;
localparam TOP_FETCH       = 4'd1;   // Descriptor 읽기 중
localparam TOP_INTERVAL    = 4'd2;   // valid=0, interval 대기
localparam TOP_WB_INPROG   = 4'd3;   // in-progress 상태 쓰기
localparam TOP_JOB_RUN     = 4'd4;   // 파이프라인 실행 중
localparam TOP_CRC_CHECK   = 4'd5;   // CRC 비교
localparam TOP_WAIT_OUT    = 4'd6;   // output_ctrl 완료 대기
localparam TOP_WB_FINAL    = 4'd7;   // 최종 결과 쓰기
localparam TOP_CHECK_FLAGS = 4'd8;   // interrupt/last 플래그 처리
localparam TOP_PAUSE       = 4'd9;   // PAUSE 상태
localparam TOP_BUS_ERR     = 4'd10;  // 버스 에러 처리
localparam TOP_IMM_STOP    = 4'd11;  // 즉시 정지
```

사양서의 STOP/ACTIVE/PAUSE 3-상태 모델이 내부적으로는 12개의 마이크로 상태로 구현된 것이다.  
문서에는 단순하게 보이지만, 실제 RTL은 늘 조금 더 수다스럽다. 그래야 모듈 간 타이밍과 책임이 분명해진다.  
이는 표준적인 하드웨어 설계 패턴이다. 외부에 보이는 상태와 내부 구현 상태를 분리하는 편이 결국 디버깅에도 유리하다.

> [IMG] **[그림 5-2]** *aes_decrypt_ctrl.v의 FSM 전환 코드가 에디터에 표시된 화면*  
> *Claude Code가 코드를 생성한 직후, 변경 사항이 diff 뷰로 표시된다*

---

### 4. AXI Manager — 가장 복잡한 모듈

`aes_decrypt_axi_mgr.v`는 4개의 독립적인 요청자(Descriptor fetch, Input read, Writeback, Output write)를 하나의 AXI4 인터페이스로 중재한다.

**사용자 →**
```
aes_decrypt_axi_mgr.v를 작성해줘.
2개의 Read 포트(RD0: desc_fetch, RD1: input_ctrl)와
2개의 Write 포트(WR0: writeback, WR1: output_ctrl)를 중재해야 해.

우선순위:
- Read: RD0 > RD1 (fixed priority)
- Write: WR0 > WR1 (fixed priority)

Outstanding 트랜잭션 수는 레지스터 설정값으로 제한해야 해.
사양서 12.3, 12.4절 참고.
```

모듈 인터페이스만 봐도 복잡도를 가늠할 수 있다.

```verilog
module aes_decrypt_axi_mgr (
    input  wire        clk,
    input  wire        rst_n,

    // --- Outstanding 제한 설정 ---
    input  wire [4:0]  max_rd_outstanding,
    input  wire [4:0]  max_wr_outstanding,

    // --- Read Port 0 (Descriptor fetch & Writeback read) ---
    input  wire [31:0] rd0_addr,
    input  wire [7:0]  rd0_len,
    input  wire        rd0_req,
    output wire        rd0_grant,
    output wire [63:0] rd0_data,
    output wire        rd0_valid,
    output wire        rd0_last,
    output wire        rd0_err,

    // --- Read Port 1 (Input buffer read) ---
    input  wire [31:0] rd1_addr,
    input  wire [7:0]  rd1_len,
    input  wire        rd1_req,
    output wire        rd1_grant,
    // ... (동일 구조)

    // --- Write Port 0 (Descriptor writeback) ---
    // --- Write Port 1 (Output buffer write) ---
    // ...

    // --- AXI4 Manager 인터페이스 (단일 포트) ---
    output wire [31:0] m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    // ... (전체 AXI4 신호)
);
```

Outstanding 트랜잭션 카운터를 구현하는 부분:

```verilog
// Read outstanding counter
reg [4:0] rd_outstanding_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_outstanding_cnt <= 5'd0;
    end else begin
        // AR 채널에서 트랜잭션 발행 시 +1, RLAST 수신 시 -1
        case ({ar_accepted, rlast_received})
            2'b10: rd_outstanding_cnt <= rd_outstanding_cnt + 1'b1;
            2'b01: rd_outstanding_cnt <= rd_outstanding_cnt - 1'b1;
            default: ; // 동시 발생 또는 변화 없음
        endcase
    end
end

// Outstanding 제한: 카운터가 한계에 도달하면 arvalid 억제
assign can_issue_rd = (rd_outstanding_cnt < max_rd_outstanding);
```

---

### 5. 데이터 흐름 — 파이프라인이 어떻게 동작하는가

한 Descriptor의 처리 흐름을 시간 순으로 보면:

```
T=0   desc_fetch가 AXI read 요청 → 32바이트 Descriptor 읽기
T=4   Descriptor 파싱 완료, in-progress 상태 쓰기(writeback) 시작
T=5   input_ctrl 시작: AES Header(16B) 먼저 읽기 → nonce, initial_ctr 추출
T=6   aes128_ctr_top에 job_start → 카운터 블록 생성 시작
T=7   ciphertext 읽기 시작 → cipher FIFO에 적재
T=7   CRC 계산 시작 (AES와 병렬)
T=8   cipher FIFO에서 데이터 → AES 파이프라인 입력
T=18  AES 파이프라인 첫 번째 출력 (10클록 지연)
T=18  output_ctrl 시작 → plaintext를 출력 버퍼에 쓰기
T=N   마지막 ciphertext 처리 → CRC 비교
T=N+1 writeback: 결과 코드(OK/CRC_ERR/...) 쓰기
T=N+2 다음 Descriptor로 이동
```

AES와 CRC가 병렬로 실행되는 것(`T=7`에서 동시 시작), AES 파이프라인의 10클록 지연(`T=8` → `T=18`)이 데이터 흐름의 핵심이다.

---

## AI에게 RTL을 요청할 때의 프롬프트 패턴

단순히 "만들어줘"가 아니라, 검증 가능한 제약을 함께 준다.  
프롬프트가 길어진다고 해서 나쁜 것이 아니다. 하드웨어에서는 대체로 그 반대다.  
말을 아낄수록 나중에 파형을 오래 보게 된다.

```
aes_decrypt_input_ctrl.v를 작성해줘.

담당 역할: 입력 버퍼를 AXI4 read로 읽어서
  1. AES Header (첫 16바이트) → nonce, initial_ctr 추출
  2. Ciphertext (IN_DATA_SIZE 바이트) → cipher FIFO에 전달
  3. Padding (IN_PAD_SIZE 바이트) → 버림
  4. CRC-32 값 (4바이트) → 래치 후 ctrl에 전달

요구사항:
- AXI 버스트는 최대 256비트 (AXI4 최대)
- AXI4 read 요청은 aes_decrypt_axi_mgr의 rd1 포트를 통해
- cipher FIFO가 가득 차면 더 이상 read 요청 보내지 말 것 (back-pressure)
- spec 11.2절 "No unnecessary bus congestion" 준수

인터페이스는 aes_decrypt_ctrl.v와 맞춰줘.
```

구체적인 제약을 함께 주면 AI가 사양을 놓치지 않는다.

---

## 첫 커밋의 코드 통계

```bash
$ find design/rtl -name "*.v" -o -name "*.vh" | \
  xargs wc -l | sort -rn | head -5

    387  aes_decrypt_axi_mgr.v
    318  aes_decrypt_ctrl.v
    285  aes_decrypt_input_ctrl.v
    243  aes128_enc_pipe.v
    198  aes_decrypt_output_ctrl.v
```

가장 복잡한 모듈은 예상대로 AXI Manager와 최상위 FSM이다.  
총 RTL 코드 라인 수는 약 2,800라인. 한 작업 세션의 결과물이다.

---

## 코드 리뷰: AI가 스스로 챙긴 것들

생성된 코드를 검토하면서 AI가 자율적으로 챙긴 것들이 눈에 띄었다.

**SVA Assertion 추가**

`project-instructions.md`에 넣은 룰대로, `ifdef` 조건부 컴파일로 assertion이 포함되어 있었다.

```verilog
`ifdef ENABLE_ASSERTIONS
// AXI spec: ARVALID이 한번 asserted되면 ARREADY 전까지 내려가면 안됨
assert property (@(posedge clk) disable iff (!rst_n)
    (m_axi_arvalid && !m_axi_arready) |=> m_axi_arvalid)
else $error("AXI AR channel: arvalid dropped before arready");
`endif
```

**헤더 주석 형식 일관성**

모든 14개 파일에 동일한 형식의 헤더가 있다.

```verilog
// =============================================================================
// File        : aes_decrypt_ctrl.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Top-level control FSM ...
// =============================================================================
```

**리셋 초기값 주석**

레지스터 선언부에 리셋 값을 명시하는 주석이 달려 있다.

```verilog
reg [1:0]  status_state;     // reset: ENG_STOP (2'b00)
reg [9:0]  cmd_head_ptr;     // reset: 10'd0
```

---

## 한계: AI가 놓친 것

물론 완벽하지 않았다. 초기 버전에서 발견된 문제들:

1. **sync_fifo의 `wr_ptr` 이중 구동** — 두 개의 `always` 블록이 같은 레지스터를 구동
2. **CRC 엔진의 초기화 타이밍** — 새 Descriptor 시작 시 초기화가 1클록 늦었음
3. **AXI Manager의 Outstanding 카운터 경계 조건** — 동시 발행+완료 시 카운터가 틀림

이 버그들은 다음 날 발견하고 수정했다. 8장에서 자세히 다룬다.

중요한 것은, **이 정도 버그는 사람이 처음 RTL을 짜도 나오는 수준**이라는 것이다.  
AI가 만든 코드라서 특별히 버그가 많은 것이 아니다.  
오히려 구조적인 실수(AXI 핸드셰이크 위반, 래치 생성 등)는 없었다.  
완벽하진 않았지만, 적어도 "처음부터 다시 써야 한다"는 종류의 재앙은 아니었다.

---

*다음 장: 6장 — 레퍼런스 소프트웨어를 만들다*
