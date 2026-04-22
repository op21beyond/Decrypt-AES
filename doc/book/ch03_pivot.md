# 3장 — 결정적 전환, 설계까지 맡겨보기로 하다

---

## 처음에는 사양서만 목표였다

이 프로젝트를 시작할 때의 목표는 단순했다.

> *"IP 구현 사양서를 빠르게 만들자. 실제 설계는 나중에, 사람이 한다."*

하드웨어 엔지니어에게 이것은 자연스러운 생각이다.  
RTL 코드는 정밀해야 하고, 프로토콜 위반 하나가 칩 전체를 망가뜨릴 수 있다.  
"AI가 그걸 제대로 할 수 있을까?"라는 의심은 당연했다.  
정확히는, 의심하지 않는 쪽이 오히려 이상하다.

그런데 사양서가 나오고 나서 생각이 바뀌었다.

---

## 전환점이 된 세 가지 관찰

### 관찰 1: 레지스터 맵이 자연스럽다

AI가 설계한 레지스터 맵에는 숙련된 엔지니어의 판단이 담겨 있었다.

- `CTRL` 레지스터의 비트를 self-clearing pulse로 설계한 것
- `AES_KEY` 레지스터를 Write-Only로 만들어 보안을 고려한 것
- `CMD_HEAD_PTR`는 Read-Only, `CMD_TAIL_PTR`는 SW가 쓰는 구조로 나눈 것
- W1C(Write-1-to-Clear) 패턴을 정확하게 적용한 것

이것들은 하드웨어 레지스터 설계의 표준 패턴들이다.  
한두 개쯤 맞히는 건 우연일 수 있지만, 이런 패턴이 연달아 자연스럽게 나오면 이야기가 달라진다.  
AI가 이 패턴들을 정확하게 선택했다는 것은, 적어도 이 문제를 "그럴듯하게 흉내" 내는 수준 이상이라는 뜻이었다.

### 관찰 2: 상태 머신이 엣지 케이스를 다룬다

일반적인 AI 출력물에서 자주 빠지는 것이 엣지 케이스 처리다.  
그런데 이 사양서에는 다음이 명시되어 있었다.

```
If last=1 and interrupt=1:
  → 엔진이 먼저 PAUSE 상태에 진입
  → SW가 CTRL.RESUME=1을 쓴 후
  → ACTIVE가 아니라 STOP으로 전환 (다음 Descriptor를 처리하지 않음)
```

`last`와 `interrupt`가 동시에 1인 경우를 정확하게 처리하고 있다.  
이 케이스는 설계자가 직접 생각해도 빠뜨리기 쉬운 부분이다.

### 관찰 3: 성능 설계가 구체적이다

단순히 "200 Mbps를 만족해야 한다"고 쓴 것이 아니라,  
그것을 달성하기 위한 **아키텍처 제약**까지 명시했다.

```markdown
## 11.2 Design Requirements to Achieve Throughput Target

1. AES core must not starve: Input FIFO must be large enough to absorb
   AXI read latency. Begin prefetching as soon as IN_ADDR and IN_DATA_SIZE
   are decoded, without waiting for full descriptor.

2. No unnecessary bus congestion: Do not issue more read transactions than
   needed to fill the internal input FIFO.

3. Descriptor overhead minimized: Fixed-size portion fetched in a single
   AXI burst to minimize read latency.
```

이것은 단순한 요구사항이 아니라 **설계 방향**이다.  
숫자만 있는 사양서가 아니라, 왜 그 숫자를 만족할 수 있는지까지 설명한 문서라는 점이 중요했다.  
이 내용이 사양서에 있다면, RTL 코드에도 그대로 반영할 수 있다.

---

## 전환 결정

이 세 가지를 확인한 뒤, 질문이 바뀌었다.

> *"AI가 이 사양서를 이해하고 쓸 수 있다면,  
> 이 사양서를 입력으로 RTL을 만들 수도 있지 않을까?"*

그리고 한 가지 더, 이미 사양서가 있다.  
RTL을 만들기 위한 **레퍼런스 문서**가 완성되어 있는 것이다.  
즉 "뭘 만들지"를 다시 설명하는 대신, "이 문서를 근거로 구현해"라고 말할 수 있다. 이 차이는 꽤 크다.  
프롬프트가 감정노동에서 지시문으로 바뀌기 때문이다.

---

## 바이브코딩 전략을 세우다

무작정 "Verilog로 만들어줘"라고 하지 않았다.  
RTL 바이브코딩을 시작하기 전에 **전략**을 먼저 잡았다.

**전략 1: 모듈을 분해하고 순서를 정한다**

AI에게 전체를 한 번에 요청하지 않는다.  
복잡한 IP는 모듈로 분해해서 하나씩 만들고, 조립한다.

```
작업 순서:
1. aes_decrypt_defs.vh   ← 파라미터, 상수 정의 (가장 먼저)
2. aes_decrypt_regfile.v ← 레지스터 파일 (가장 독립적)
3. aes128_key_sched.v    ← AES 키 스케줄 (암호화 코어)
4. aes128_enc_pipe.v     ← AES 파이프라인 코어
5. aes128_ctr_top.v      ← CTR 모드 래퍼
6. crc32_engine.v        ← CRC 엔진
7. sync_fifo.v           ← 범용 FIFO
8. aes_decrypt_desc_fetch.v ← Descriptor 읽기
9. aes_decrypt_input_ctrl.v ← 입력 버퍼 컨트롤러
10. aes_decrypt_output_ctrl.v ← 출력 버퍼 컨트롤러
11. aes_decrypt_writeback.v ← Descriptor 상태 쓰기
12. aes_decrypt_axi_mgr.v ← AXI Manager (모든 채널 중재)
13. aes_decrypt_ctrl.v   ← 최상위 FSM (가장 마지막)
14. aes_decrypt_engine.v ← 최상위 래퍼 (배선)
```

의존성이 낮은 모듈부터 시작해서, 복잡한 것은 나중에 만드는 방식이다.

**전략 2: 사양서를 항상 참조한다**

```
# 각 모듈 작성 시 프롬프트 패턴
"spec/AES-Decrypt-IP-Specification.md의 [섹션 번호]를 참고해서
[모듈명].v를 작성해줘.
합성 가능해야 하고, ASIC 환경에서 문제없어야 해."
```

**전략 3: 모듈마다 헤더 주석 형식을 통일한다**

```
// ===========================================================
// File        : 파일명.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : 모듈 설명
// ===========================================================
```

이 형식을 처음에 한 번 정해두면, AI가 이후 모든 파일에서 동일하게 유지한다.

**전략 4: project-instructions.md에 설계 룰을 추가한다**

```markdown
## IP 설계 요구사항 (Verilog)
1. 사양서대로 하드웨어를 Verilog로 구현
2. 고성능 파이프라인 구조:
   - Descriptor 고정 크기는 한 번에 읽어 해석
   - IN_ADDR, IN_DATA_SIZE 확인 즉시 미리 read 시작
3. 합성 가능, ASIC 환경에서 문제없어야 함
4. Divider, Wide-bit multiplier 사용 금지
5. 생산 가능한 수준의 완성도
6. 옵션으로 on/off 가능한 (`define) SVA Assertion 및 Coverage 추가
```

이 룰이 `project-instructions.md`에 들어가면,  
이후 모든 Verilog 작성 요청에서 AI가 자동으로 이 기준을 따른다.

---

## "바이브코딩"이 "묻지마 코딩"이 아닌 이유

여기서 한 가지 오해를 짚고 싶다.

바이브코딩은 AI에게 무조건 맡기는 것이 아니다.  
오히려 **더 많은 판단**이 엔지니어에게 요구된다.  
손이 덜 바빠지는 대신, 머리는 더 자주 깨어 있어야 한다.

- 모듈을 어떻게 분해할 것인가?
- 어떤 인터페이스로 연결할 것인가?
- AI가 만든 코드가 사양과 일치하는지 검토할 수 있는가?
- 버그가 생겼을 때 어디를 보아야 하는가?

이 판단들은 모두 도메인 지식에서 나온다.  
바이브코딩은 도메인 지식이 필요 없는 방식이 아니라,  
**도메인 지식 있는 엔지니어의 생산성을 극대화하는 방식**이다.

---

## 한 가지 더: 사람이 반드시 검토해야 하는 것

설계를 AI에게 맡기더라도, 결과를 사람이 검토해야 하는 부분이 있다.

1. **AXI 프로토콜 준수 여부** — handshake 타이밍, outstanding count 처리
2. **리셋 후 초기 상태** — 모든 레지스터가 사양서의 reset value와 일치하는지
3. **엣지 케이스** — FIFO가 가득 찬 상태에서 쓰기 요청이 오는 경우 등
4. **합성 경고** — AI가 만든 코드가 래치(latch)를 만들지 않는지

이것들은 코드 리뷰 체크리스트로 만들 수 있다.  
그리고 체크리스트 자체도 AI에게 만들어달라고 할 수 있다.

---

*다음 장: 4장 — 프로젝트의 골격을 세우다*
