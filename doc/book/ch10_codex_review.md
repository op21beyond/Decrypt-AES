# 10장 — 다른 AI를 리뷰어로 부르다

---

## 같은 AI에게만 물으면 생기는 문제

Claude와 함께 3일 동안 개발하면서 한 가지 한계를 체감했다.  
정확히는, "혼자 잘 달리는 AI"에게도 결국 리뷰어는 필요하다는 사실을 깨닫게 된다.

AI도 **확증 편향(confirmation bias)**이 있다.  
Claude가 만든 코드를 Claude에게 리뷰 요청하면, 자신이 만든 코드를 너무 관대하게 평가한다.  
"이 코드가 올바른가?"라고 물으면 대부분 "네, 맞습니다"라고 답하거나, 사소한 개선만 제안한다.

진짜 리뷰는 **독립적인 시각**에서 나온다.  
사람 팀에서도 작성자와 리뷰어를 굳이 나누는 데는 이유가 있다. AI라고 갑자기 그 원리를 초월하진 않는다.

해결책: **다른 AI를 리뷰어로 투입한다.**  
조금 우스운 그림처럼 들릴 수 있다. AI가 짠 코드를 다른 AI가 보고, 그걸 사람이 판정한다.  
그런데 막상 해보면 꽤 합리적이다. 리뷰어가 바뀌면 질문의 결도 바뀌고, 놓친 패턴도 달라진다.

이 프로젝트에서는 OpenAI **Codex** (또는 ChatGPT with code analysis)를 리뷰어로 활용했다.  
Claude가 만든 코드를 Codex에게 보내서 "이 코드의 문제점을 찾아줘"라고 요청했다.

---

## Codex 리뷰를 위한 준비

리뷰 요청 시 컨텍스트를 충분히 제공해야 효과적이다.  
좋은 리뷰는 좋은 질문에서 나오고, 좋은 질문은 대체로 배경 설명을 아끼지 않을 때 나온다.

**Codex에게 보낸 리뷰 요청 구조:**

```
다음은 AES-128 CTR 모드 복호화 하드웨어 IP의 Verilog RTL 코드야.
ASIC 구현을 목표로 하고, AXI4 인터페이스를 사용해.

배경:
- Memory-to-memory 방식, Descriptor 기반 DMA
- AXI4 64-bit Manager (최대 outstanding 16개)
- AXI4-Lite Subordinate (레지스터 인터페이스)
- 목표 처리량: 200 Mbps at 200 MHz

다음 관점에서 코드 리뷰를 해줘:
1. AXI4 프로토콜 준수 여부 (핸드셰이크 타이밍, outstanding count 처리)
2. 합성 문제 가능성 (래치 생성, 조합 루프, 멀티 드라이버)
3. 리셋 동작 완전성 (모든 레지스터가 안전한 초기 상태)
4. 코너 케이스 (FIFO 경계 조건, 버스 에러 중 flush 동작)
5. 성능 병목 가능성

[코드 첨부]
```

---

## Codex가 발견한 주요 이슈들

### 이슈 1: AXI AR 채널 — arvalid 철회 위험

**Codex 코멘트:**
```
aes_decrypt_axi_mgr.v에서 outstanding 카운터가 한계에 도달했을 때
arvalid를 즉시 de-assert합니다.

AXI4 스펙(섹션 A3.2.1):
"Once ARVALID is asserted, it must remain asserted until the rising
clock edge after ARREADY is asserted."

만약 arvalid가 asserted된 상태에서 (한계 초과 등으로) de-assert되면
AXI 스펙 위반입니다.
```

**확인 결과:**  
실제 코드를 보니, `arvalid`가 grant 전에 내려갈 수 있는 경로가 있었다.  
이런 버그는 시뮬레이션에서 바로 터지지 않을 수도 있어서 더 위험하다. "가끔은 된다"는 종류의 문제는 늘 오래 산다.

**Claude에게 수정 요청:**
```
aes_decrypt_axi_mgr.v에서 AXI 스펙 위반 가능성이 있어.
arvalid를 asserted한 후 arready 전에 de-assert하면 안 돼.
이걸 막는 로직을 추가해줘.
```

**수정된 코드:**
```verilog
// arvalid는 한번 assert되면 arready 전에 내려갈 수 없음
// pending_ar 플래그로 진행 중인 AR 트랜잭션 추적
reg pending_ar;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pending_ar <= 1'b0;
    end else begin
        if (m_axi_arvalid && m_axi_arready)
            pending_ar <= 1'b0;   // 수락됨
        else if (m_axi_arvalid)
            pending_ar <= 1'b1;   // 발행 중, 철회 불가
    end
end

// arvalid: 새 요청이 있고 outstanding 한계 미달일 때, 또는 이미 pending
assign m_axi_arvalid = pending_ar ||
                       (rd_req_arb && can_issue_rd && !pending_ar);
```

---

### 이슈 2: 버스 에러 중 Outstanding 트랜잭션 처리

**Codex 코멘트:**
```
버스 에러 발생 시 "모든 outstanding 트랜잭션이 완료될 때까지 STOP 대기"라고
사양서에 명시되어 있습니다.

현재 코드(TOP_BUS_ERR 상태)에서는 rd_outstanding_cnt만 확인하고 있는데,
wr_outstanding_cnt도 0이 될 때까지 기다려야 하지 않나요?

또한, SLVERR 응답이 읽기와 쓰기 동시에 발생하면 state가 어떻게 됩니까?
```

**확인 결과:**  
쓰기 outstanding 카운터를 드레인하지 않고 STOP으로 진입하는 경로가 있었다.  
단일 에러만 기준으로 설계했고, 동시 에러 케이스를 빠뜨렸다.

**수정 방향:**
```verilog
// TOP_BUS_ERR: 읽기와 쓰기 모두 드레인 완료 후 STOP
TOP_BUS_ERR: begin
    if (rd_outstanding_cnt == 5'd0 &&
        wr_outstanding_cnt == 5'd0) begin
        state <= TOP_STOP;
        status_state <= `ENG_STOP;
    end
    // 에러 발생 후 새 트랜잭션 발행 억제는 bus_err_flag로 처리
end
```

---

### 이슈 3: CRC 엔진 알고리즘 전환 타이밍

**Codex 코멘트:**
```
CRC_CTRL.ALG_SEL 레지스터가 사양서에 따르면
"Writes are accepted at any time; the selected algorithm applies
to descriptors processed after the write."

그런데 현재 crc32_engine.v는 alg_sel 신호가 바뀌면 즉시 내부 상태에 영향을 줍니다.
Descriptor 처리 중간에 ALG_SEL이 바뀌면 CRC 결과가 섞일 수 있습니다.
```

**수정:**  
Descriptor 처리 시작 시(`TOP_WB_INPROG` 상태)에 `alg_sel`을 래치해서,  
처리 중간에 레지스터가 변경되더라도 같은 알고리즘으로 끝까지 처리하도록 했다.  
사양을 글로 읽으면 당연해 보이는데, 코드에서는 의외로 쉽게 빠지는 부분이다.

```verilog
// Descriptor 처리 시작 시 alg_sel 래치
reg crc_alg_latched;

always @(posedge clk) begin
    if (state == TOP_WB_INPROG)
        crc_alg_latched <= crc_alg_sel;  // 시작 시점에 고정
end

// CRC 엔진에는 래치된 값을 사용
assign crc_alg = crc_alg_latched;
```

---

## Codex 리뷰의 가치 — 정량적으로

| 발견 이슈 | 심각도 | 발견 방법 |
|---|---|---|
| AXI arvalid 철회 위험 | 높음 (프로토콜 위반) | Codex 리뷰 |
| Write outstanding 드레인 누락 | 중간 (버스 에러 시 undefined state) | Codex 리뷰 |
| CRC 알고리즘 중간 전환 | 낮음 (엣지 케이스) | Codex 리뷰 |

이 중 첫 번째 이슈(AXI arvalid 철회)는 실제 SoC에 통합했을 때 다른 IP와의 연동에서 간헐적 버그를 유발했을 것이다.  
재현하기 어렵고 원인을 찾기도 어려운 종류의 버그다. 흔히 말하는 "회의에서는 재현 안 되고, 데모 직전에만 나오는" 부류에 가깝다.

---

## AI 협업에서 다중 AI 활용 전략

이 경험에서 도출한 원칙:

**Claude (개발자 역할)**
- 코드 생성
- 리팩토링
- 설계 결정 지원

**Codex (리뷰어 역할)**
- 독립적인 시각으로 코드 검토
- 프로토콜 스펙 준수 확인
- 엣지 케이스 발굴

두 AI의 강점이 다르고, 만들어내는 오류의 패턴도 다르다.  
한 AI가 놓친 것을 다른 AI가 잡아내는 상호 보완 관계가 된다.  
사람 팀에서 성향 다른 리뷰어 둘이 붙으면 품질이 올라가는 것과 비슷한 원리다.

---

## 리뷰어 AI에게 효과적으로 요청하는 법

무조건 "이 코드 리뷰해줘"가 아니다.

```
✗ "이 Verilog 코드 리뷰해줘"
  → 너무 막연함, 표면적인 것만 보게 됨

✓ "AXI4 프로토콜 스펙의 섹션 A3.2.1을 기준으로,
   arvalid/arready 핸드셰이크 처리에 위반이 있는지 확인해줘"
  → 구체적인 기준이 있어서 정밀한 리뷰가 가능

✓ "버스 에러 처리 경로에서 데드락 가능성이 있는지 추적해줘.
   특히 outstanding 카운터가 0으로 내려오지 않는 케이스를 찾아줘"
  → 목표가 명확해서 AI가 집중할 수 있음
```

---

*다음 장: 에필로그 — AI 동료와 일한다는 것*
