# 4장 — 프로젝트의 골격을 세우다

---

## 폴더 구조가 AI 협업의 품질을 결정한다

바이브코딩에서 폴더 구조는 단순한 파일 정리 이상의 의미를 가진다.  
AI는 파일을 읽을 때 **경로와 위치**로 맥락을 파악한다.  
사람이 "아, 이건 테스트용이구나" 하고 눈치로 이해하는 것을, AI는 폴더 이름과 파일 배치로 배운다.

`design/rtl/` 폴더에 있는 `.v` 파일은 RTL 소스다.  
`design/tb/` 폴더에 있는 파일은 시뮬레이션 환경이다.  
`host_software/` 폴더에 있는 `.c` 파일은 C 드라이버 코드다.

폴더 구조가 명확하면 AI에게 "tb_top.v를 수정해줘"라고 했을 때  
AI가 스스로 `design/tb/tb_top.v`를 찾아 읽고 작업한다.  
구조가 모호하면 AI는 추측하거나 물어봐야 한다.

---

## 확정된 폴더 구조

```
Decrypt-AES/
│
├── prompt/
│   ├── project-instructions.md   ← 전체 규약 + 확정 결정사항 (AI 컨텍스트 파일)
│   └── original-prompt.md        ← 최초 요청 원문 (기록용)
│
├── spec/
│   └── AES-Decrypt-IP-Specification.md   ← IP 구현 사양서
│
├── design/
│   ├── rtl/
│   │   ├── inc/
│   │   │   └── aes_decrypt_defs.vh      ← 전역 파라미터, define
│   │   ├── crypto/
│   │   │   ├── aes128_key_sched.v       ← AES 키 스케줄 (조합 논리)
│   │   │   ├── aes128_enc_pipe.v        ← AES 10라운드 파이프라인
│   │   │   └── aes128_ctr_top.v         ← CTR 모드 래퍼
│   │   ├── util/
│   │   │   ├── sync_fifo.v              ← 범용 동기 FIFO
│   │   │   ├── crc32_engine.v           ← CRC-32 엔진
│   │   │   ├── sram_2p.v                ← 2-port SRAM 기본 모델
│   │   │   ├── sram_2p_32x64.v          ← 32x64 SRAM 인스턴스
│   │   │   └── sram_2p_32x72.v          ← 32x72 SRAM 인스턴스
│   │   ├── aes_decrypt_engine.v         ← 최상위 (DUT top)
│   │   ├── aes_decrypt_regfile.v        ← AXI4-Lite 레지스터 파일
│   │   ├── aes_decrypt_ctrl.v           ← 최상위 FSM
│   │   ├── aes_decrypt_desc_fetch.v     ← Descriptor 읽기
│   │   ├── aes_decrypt_input_ctrl.v     ← 입력 버퍼 컨트롤러
│   │   ├── aes_decrypt_output_ctrl.v    ← 출력 버퍼 컨트롤러
│   │   ├── aes_decrypt_writeback.v      ← Descriptor 상태 쓰기
│   │   ├── aes_decrypt_axi_mgr.v        ← AXI4 Manager (2R+2W)
│   │   └── aes_decrypt_mem_top.v        ← SRAM 집합체 (MBIST 경계)
│   │
│   ├── tb/
│   │   ├── tb_top.v        ← 시뮬레이션 최상위
│   │   ├── tb_core.sv      ← 테스트 시나리오 (task 모음)
│   │   ├── tb_defines.vh   ← 테스트벤치 파라미터
│   │   ├── fake_mem.v      ← AXI4 Subordinate 메모리 모델
│   │   ├── gen_mem.c       ← 메모리 초기화 파일 생성기 (C)
│   │   ├── mem_init.hex    ← readmemh 초기화 파일
│   │   └── run.sh          ← NCVerilog 실행 스크립트
│   │
│   ├── tb_verilator/
│   │   ├── tb_top_verilator.sv  ← Verilator용 TB 최상위
│   │   ├── tb_dpi.cpp           ← C++ 시뮬레이션 드라이버
│   │   ├── run.sh               ← Verilator 빌드/실행 스크립트
│   │   └── README.md
│   │
│   └── syn/
│       ├── run_dc.tcl       ← Synopsys DC 합성 스크립트
│       └── constraints.sdc  ← 타이밍 제약 (SDC)
│
├── host_software/
│   ├── aes128_ctr.c/.h     ← Pure C AES-128 CTR (레퍼런스)
│   ├── crc32.c/.h          ← Pure C CRC-32 (레퍼런스)
│   ├── aes_decrypt_ip.c/.h ← IP 레지스터 드라이버
│   ├── test_vectors.h      ← 테스트 벡터 (암호화 데이터 + 키)
│   ├── tc_params.h         ← 테스트 케이스 파라미터
│   ├── ip_test.c           ← IP 사용 테스트 (드라이버 기반)
│   └── sw_test.c           ← 순수 SW 구현 테스트
│
├── doc/
│   ├── AES-Decrypt-IP-Architecture-Description.md
│   └── compiled_memory_list.txt
│
└── README.md               ← 프로젝트 개요, 빠른 시작
```

---

## 이 구조의 설계 원칙

### 원칙 1: 용도별 분리

`design/rtl/` 에는 합성에 들어가는 소스만 있다.  
`design/tb/` 에는 시뮬레이션 전용 코드만 있다.  
`design/syn/` 에는 합성 스크립트만 있다.

이 분리는 AI에게도 명확한 신호가 된다.  
"tb_top.v 수정"이라고 했을 때 AI가 RTL 소스를 건드리지 않는다.  
디렉터리 구조가 어수선하면 AI도 어수선하게 일한다. 사람과 크게 다르지 않다.

### 원칙 2: 계층 구조

`design/rtl/` 안에 `crypto/`, `util/`, `inc/` 하위 폴더를 두었다.  
이는 모듈의 역할을 계층으로 표현한 것이다.

- `inc/` — 전역 정의 (모든 모듈이 포함)
- `util/` — 재사용 가능한 기본 블록 (FIFO, CRC, SRAM)
- `crypto/` — 암호화 전용 코어
- 루트 — 프로젝트 특화 모듈

### 원칙 3: prompt/ 폴더의 역할

이 폴더는 일반적인 IP 프로젝트에는 없는 폴더다.  
바이브코딩 프로젝트에서 이 폴더는 **AI와의 계약서 역할**을 한다.  
물론 법적 효력은 없지만, 체감상으로는 꽤 강력하다.

`project-instructions.md` 파일에는 다음이 담긴다.

- 확정된 설계 결정 사항
- 문서 작성 규칙 (회사명, 용어 표기 방식)
- 코드 작성 규칙 (Divider 금지, SVA 추가 등)
- 폴더 구조와 각 폴더의 역할

새 대화를 시작할 때 이 파일 하나만 참조하면 AI가 즉시 프로젝트 맥락을 이해한다.

---

## git 전략: 단순하게

복잡한 브랜치 전략은 쓰지 않았다.  
바이브코딩에서는 생성과 수정의 템포가 빨라서, 멋진 전략보다 자주 끊어 저장하는 습관이 더 중요하다.  
말하자면 "정교한 체스"보다 "자주 세이브" 쪽에 가깝다.

```bash
# 이 프로젝트의 커밋 패턴
git add -p    # 변경 내용을 확인하면서 스테이징
git commit -m "update"
```

커밋 메시지가 단순한("update") 것은 의도적인 선택이었다.  
3일간의 빠른 반복에서 메시지 작성에 시간을 쓰지 않았다.  
실제 프로젝트라면 의미 있는 메시지가 좋겠지만, 프로토타이핑 단계에서는 **커밋 자체**가 중요하다.

```
5404a78 update   ← GitHub Actions CI 추가
c4c439a update   ← Verilator 테스트벤치 추가
dfff9c6 update   ← RTL 버그 수정 (CRC, AXI)
dfed89d update   ← SRAM 모델, 합성 스크립트, 아키텍처 문서
2947352 update   ← 테스트 파라미터 추가
c1611de update   ← NCVerilog 테스트벤치
1072883 update   ← 호스트 소프트웨어
ca20700 initial  ← 사양서 + 전체 RTL (첫 커밋)
```

첫 커밋(`ca20700`)에 이미 사양서와 전체 RTL이 포함된 것에 주목하라.  
사양서 → RTL 전환이 얼마나 빠르게 이루어졌는지 보여준다.

---

## 룰 설정이 AI 출력 품질을 높이는 방법

`project-instructions.md`에 넣은 룰 중 실제로 차이를 만든 것들:

**용어 표기 룰**
```
Master → Manager, Slave → Subordinate
불가피한 경우: M a s t e r, S l a v e (글자 사이 공백)
```
이 룰 덕분에 생성된 모든 문서와 주석이 일관된 용어를 사용했다.  
AI에게 일일이 교정을 요청하지 않아도 됐다.

**영어 작성 룰**
```
모든 작성물은 영어로 작성.
```
레지스터 설명, 모듈 주석, 사양서가 모두 영어로 나왔다.

**일관성 유지 룰**
```
어느 하나에 수정이 있을 경우 프로젝트 내 모든 코드, 문서가
일관성을 유지하도록 함께 반영할 것.
```
레지스터 맵이 변경되면 사양서, 드라이버 헤더, 테스트벤치 task를 함께 수정하도록 한 것이다.  
이 룰이 없으면 코드가 빠르게 발산한다.

---

## 구조를 먼저 만드는 것의 가치

바이브코딩 초보자가 가장 자주 하는 실수는 **구조 없이 바로 코드를 요청하는 것**이다.

```
# 잘못된 시작
"AES decrypt IP Verilog 코드 만들어줘"
```

이렇게 하면 AI는 어딘가에 파일을 만들지만, 프로젝트에 통합되지 않는다.  
나중에 테스트벤치를 요청하면 파일 경로가 맞지 않고, 드라이버 코드를 요청하면 레지스터 주소가 어긋난다.

```
# 올바른 시작
1. 폴더 구조를 만든다
2. project-instructions.md에 룰을 정의한다
3. 그 구조 안에서 파일을 하나씩 생성한다
```

구조가 있으면 AI의 모든 출력이 **그 구조의 일부**로 생성된다.  
그래서 나중에 테스트벤치, 드라이버, 문서가 서로 다른 세계관에서 태어나는 일을 줄일 수 있다.  
이것이 대규모 IP를 바이브코딩할 때 유지보수 가능한 코드베이스가 만들어지는 이유다.

---

*다음 장: 5장 — RTL을 바이브코딩하다*
