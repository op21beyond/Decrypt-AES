# 7장 — 검증 환경을 구축하다

---

## 테스트벤치도 바이브코딩한다

RTL 설계를 마쳤다면 이제 시뮬레이션으로 검증할 차례다.  
테스트벤치 역시 AI가 만들었다. 그리고 이 역시 하루 만에 구조를 갖췄다.

여기서부터는 프로젝트의 분위기가 조금 달라진다.  
코드를 "만드는" 단계에서, 코드를 "의심하는" 단계로 넘어가기 때문이다. 엔지니어에게는 대체로 이쪽이 더 익숙하다.

---

## 시뮬레이션 환경의 구조

```
          ┌──────────────────────────────────────────┐
          │           tb_top.v (최상위)               │
          │                                          │
          │  ┌──────────────┐   ┌──────────────────┐ │
          │  │ Fake Host    │   │    DUT            │ │
          │  │ CPU          │   │ (aes_decrypt_     │ │
          │  │              │   │  engine.v)        │ │
          │  │ AXI4-Lite    │◄──►                   │ │
          │  │ Manager      │   │ AXI4 Manager ◄────┼─┼──┐
          │  │              │   │                   │ │  │
          │  │ IRQ Handler  │◄──┤ irq               │ │  │
          │  └──────────────┘   └──────────────────┘ │  │
          │                                          │  │
          │  ┌──────────────────────────────────────┐│  │
          │  │         Fake Memory                   ││◄─┘
          │  │  (AXI4 Subordinate + readmemh)        ││
          │  └──────────────────────────────────────┘│
          └──────────────────────────────────────────┘
```

세 구성 요소:
- **Fake Host CPU** — AXI4-Lite write/read task로 레지스터 제어, 인터럽트 처리
- **DUT** — `aes_decrypt_engine.v` (검증 대상)
- **Fake Memory** — AXI4 Subordinate, `readmemh`로 초기화, DUT의 AXI4 Manager 요청 처리

구조만 보면 단순해 보이지만, 사실상 작은 SoC를 축소 모형으로 만든 셈이다.  
좋은 테스트벤치는 DUT만 똑똑한 게 아니라, 주변 세계도 그럴듯해야 한다.

---

## Fake Memory 설계 — fake_mem.v

**사용자 →**
```
design/tb/fake_mem.v를 작성해줘.
AXI4 Subordinate로 동작하는 간단한 메모리 모델이야.

요구사항:
- 메모리 크기: 파라미터로 설정 (기본 64KB)
- readmemh로 초기화 가능
- AXI4 burst 지원 (INCR 타입)
- 64-bit 데이터폭 (DUT AXI Manager와 맞춤)
- 랜덤 지연 가능 (ready를 랜덤하게 de-assert, 실제 메모리 동작 시뮬레이션)
- 시뮬레이션 전용이므로 합성 가능성 불필요
```

핵심 부분은 메모리 모델이 너무 똑똑하지도, 너무 멍청하지도 않게 만드는 데 있다.  
현실적인 지연은 주되, 분석 불가능할 정도로 혼란스럽지는 않아야 한다.

```verilog
// fake_mem.v — AXI4 Read 응답 처리 (간략화)
always @(posedge clk) begin
    if (ar_accepted) begin
        // 버스트 읽기 트랜잭션 등록
        rd_addr  <= axi_araddr;
        rd_len   <= axi_arlen;
        rd_count <= 8'd0;
        rd_busy  <= 1'b1;
    end

    if (rd_busy && r_accepted) begin
        // 다음 Beat 주소 계산 (INCR burst)
        rd_addr  <= rd_addr + 8;     // 64-bit = 8 bytes/beat
        rd_count <= rd_count + 1'b1;

        if (rd_count == rd_len) begin  // 마지막 beat
            rd_busy  <= 1'b0;
            axi_rlast <= 1'b1;
        end
    end
end

// 메모리 읽기 (64-bit aligned)
assign axi_rdata = mem_array[rd_addr[ADDR_WIDTH-1:3]];
```

---

## 메모리 초기화 파일 생성 — gen_mem.c

테스트 데이터를 메모리에 배치하는 것도 자동화했다.  
직접 손으로 집어넣기 시작하면, 금방 "이 바이트를 내가 왜 여기 넣었지?"라는 질문과 마주치게 된다.

`gen_mem.c`는 C 프로그램으로, 다음을 수행한다.

1. `test_vectors.h`에서 테스트 데이터 읽기
2. 메모리 레이아웃 계산 (Descriptor 위치, 입력 버퍼 위치, 출력 버퍼 위치)
3. AES Header, ciphertext, padding, CRC를 입력 버퍼에 배치
4. `mem_init.hex` 파일 출력 (`$readmemh` 형식)

```c
/* gen_mem.c — 메모리 레이아웃 생성 (핵심 부분) */
#define DESC_BASE    0x00001000   /* Descriptor 링 버퍼 시작 */
#define IN_BUF_BASE  0x00002000   /* 입력 버퍼 시작 */
#define OUT_BUF_BASE 0x00004000   /* 출력 버퍼 시작 */

/* Descriptor 0 작성 */
write32(mem, DESC_BASE + 0x00, 0x00000001);  /* valid=1 */
write32(mem, DESC_BASE + 0x04, IN_BUF_BASE);
write32(mem, DESC_BASE + 0x08, OUT_BUF_BASE);
write32(mem, DESC_BASE + 0x0C,
    (TC1_IN_PAD_SIZE << 24) | TC1_IN_DATA_SIZE);
write32(mem, DESC_BASE + 0x10,
    (TC1_OUT_PAD_SIZE << 24) | TC1_OUT_DATA_SIZE);

/* 입력 버퍼: AES Header 배치 */
memcpy(mem + IN_BUF_BASE + 0x00, TC1_NONCE, 12);
write32(mem, IN_BUF_BASE + 0x0C, TC1_INITIAL_CTR);

/* 입력 버퍼: Ciphertext 배치 */
memcpy(mem + IN_BUF_BASE + 0x10, TC1_CIPHERTEXT, TC1_IN_DATA_SIZE);

/* 입력 버퍼: CRC 배치 */
write32(mem, IN_BUF_BASE + 0x10 + TC1_IN_DATA_SIZE, TC1_CRC32);
```

---

## 테스트 시나리오 — tb_core.sv

실제 테스트 시나리오는 `tb_core.sv`에 task로 구현했다.  
이 파일은 말하자면 검증팀의 대본이다. DUT가 어떤 장면에서 어떤 반응을 보여야 하는지 한 장면씩 적혀 있다.

**사용자 →**
```
design/tb/tb_core.sv를 작성해줘.
테스트 시나리오들이 담긴 파일이야.

다음 시나리오를 task로 구현해줘:
1. basic_decrypt_test: TC1 (정상 복호화)
2. crc_error_test: TC3 (CRC 오류 케이스)
3. interrupt_pause_resume_test: interrupt=1인 Descriptor 처리
4. last_descriptor_test: last=1인 Descriptor 후 STOP 확인
5. multi_descriptor_test: 여러 Descriptor 연속 처리

각 task는 레지스터 설정 → IP 시작 → 완료 대기 → 결과 검증 순서로.
검증 실패 시 $error로 메시지 출력.
```

```systemverilog
// tb_core.sv — 기본 복호화 테스트 (간략화)
task basic_decrypt_test;
    $display("[TEST] basic_decrypt_test start");

    // 1. AES 키 설정
    axil_write(AES_KEY_0, TC1_KEY_W0);
    axil_write(AES_KEY_1, TC1_KEY_W1);
    axil_write(AES_KEY_2, TC1_KEY_W2);
    axil_write(AES_KEY_3, TC1_KEY_W3);

    // 2. 링 버퍼 설정
    axil_write(CMD_BUF_ADDR, DESC_BASE);
    axil_write(CMD_BUF_SIZE, 32'd4);    // 4-slot ring
    axil_write(CMD_TAIL_PTR, 32'd1);    // 1개 Descriptor 준비됨

    // 3. IP 시작
    axil_write(CTRL, 32'h1);            // CTRL.START=1

    // 4. 완료 대기 (polling)
    begin : wait_loop
        integer timeout;
        timeout = 10000;
        forever begin
            axil_read(STATUS, rd_data);
            if ((rd_data & 2'b11) == STATE_STOP) begin
                disable wait_loop;
            end
            @(posedge clk);
            if (--timeout == 0) begin
                $error("TIMEOUT: IP did not reach STOP");
                disable wait_loop;
            end
        end
    end

    // 5. 결과 검증: 출력 버퍼 내용 확인
    for (int i = 0; i < TC1_OUT_DATA_SIZE; i += 8) begin
        expected = {TC1_PLAINTEXT[i+7], TC1_PLAINTEXT[i+6],
                    TC1_PLAINTEXT[i+5], TC1_PLAINTEXT[i+4],
                    TC1_PLAINTEXT[i+3], TC1_PLAINTEXT[i+2],
                    TC1_PLAINTEXT[i+1], TC1_PLAINTEXT[i+0]};
        actual   = fake_mem.mem_array[(OUT_BUF_BASE + i) >> 3];
        if (actual !== expected)
            $error("[FAIL] Output mismatch at +0x%0x: got %016h, exp %016h",
                   i, actual, expected);
    end

    // 6. Descriptor 상태 확인
    desc_state = fake_mem.mem_array[DESC_BASE >> 3] >> 8;  // Byte 1
    if (desc_state !== 8'h01)
        $error("[FAIL] Descriptor state: got %02h, expected 0x01 (OK)",
               desc_state[7:0]);

    $display("[PASS] basic_decrypt_test");
endtask
```

---

## NCVerilog 실행 스크립트

```bash
# design/tb/run.sh
ncverilog \
  +access+r \
  +fsdb+all \
  -f rtl_filelist.f \
  -f tb_filelist.f \
  +incdir+../rtl/inc \
  +define+ENABLE_ASSERTIONS \
  tb_top.v \
  2>&1 | tee sim.log
```

`+define+ENABLE_ASSERTIONS`를 주면 RTL에 삽입된 SVA assertion이 활성화된다.  
이 어서션들이 AXI 프로토콜 위반을 시뮬레이션 중에 잡아낸다.  
파형을 두 시간째 보다가 겨우 알아낼 실수를, 어서션은 몇 초 만에 "거기 틀렸습니다"라고 말해준다. 매너는 없지만 효율은 좋다.

---

## Verilator 테스트벤치 — 오픈소스로의 전환

NCVerilog는 라이선스가 필요한 상용 툴이다.  
이후에 오픈소스로 CI를 구축하기 위해 Verilator용 테스트벤치도 별도로 만들었다.

Verilator는 SystemVerilog → C++ 변환 후 컴파일해서 실행하는 방식이다.  
C++ 드라이버가 필요하다.  
처음엔 약간 우회로처럼 느껴지지만, CI에 올리기 시작하면 이 선택이 왜 현실적인지 곧 체감하게 된다.

```cpp
// tb_dpi.cpp — Verilator 시뮬레이션 메인 루프 (핵심)
while (!context.gotFinish()) {
    // 클록 Rising Edge
    g_clk = 1;
    context.timeInc(kHalfPeriodNs);
    top->clk = g_clk;
    top->rst_n = g_rst_n;
    eval_step();

    // 클록 Falling Edge
    g_clk = 0;
    context.timeInc(kHalfPeriodNs);

    // 리셋 해제 타이밍
    if (context.time() >= kResetReleaseNs)
        g_rst_n = 1;

    top->clk = g_clk;
    eval_step();
}
```

SystemVerilog DPI를 통해 C++ 함수와 SystemVerilog task가 통신한다.

> [IMG] **[그림 7-1]** *Verilator 빌드 + 시뮬레이션 실행 결과가 터미널에 출력되는 화면*  
> *`[PASS] basic_decrypt_test` 메시지가 출력되고 exit code 0으로 종료*

---

## 테스트벤치가 잡아내는 것

시뮬레이션 환경이 갖춰지면서 검증할 수 있는 항목들이 눈에 띄게 늘어난다.  
이 시점부터는 "돌아간다"보다 "어디까지 믿을 수 있는가"를 말할 수 있게 된다.

| 검증 항목 | 방법 |
|---|---|
| AES 복호화 정확성 | 출력 버퍼와 레퍼런스 SW 결과 비교 |
| CRC 오류 감지 | 잘못된 CRC로 설정한 케이스에서 Descriptor 상태 확인 |
| 인터럽트 동작 | PAUSE → IRQ → RESUME → ACTIVE 흐름 시뮬레이션 |
| last 플래그 동작 | 마지막 Descriptor 후 STOP 확인 |
| AXI 프로토콜 | SVA assertion이 핸드셰이크 위반 감지 |
| 버스 에러 처리 | fake_mem에서 SLVERR 응답 주입 |

---

*다음 장: 8장 — 버그를 찾고 고치다*
