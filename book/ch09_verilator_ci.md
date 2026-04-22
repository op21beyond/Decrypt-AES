# 9장 — 오픈소스 CI로 자동화하다

---

## 왜 CI가 필요한가

RTL을 손으로 고쳐가면서 매번 시뮬레이션을 수동으로 돌리는 방식에는 문제가 있다.  
코드를 수정했을 때 무언가 부러졌는지 즉시 알 수가 없다.

작을 때는 괜찮다. "이번 한 번쯤은 내가 기억하지"라고 생각할 수 있다.  
하지만 파일이 늘고 수정 속도가 빨라지면, 그 기억력은 생각보다 금방 파산한다.

소프트웨어 세계에서는 이것이 CI/CD로 해결된 지 오래다.  
Push할 때마다 자동으로 테스트가 돌고, 결과를 알려준다.

하드웨어에도 이 패턴을 적용할 수 있다.  
상용 EDA 툴(NCVerilog, VCS)은 CI 환경에서 쓰기 어렵다. 라이선스 서버가 필요하고, 비용이 크다.  
그러나 **Verilator**는 오픈소스이고, GitHub Actions에서 무료로 돌릴 수 있다.  
물론 상용 시뮬레이터를 완전히 대체하는 것은 아니다. 하지만 "코드가 오늘도 최소한의 상식을 지키는가"를 확인하는 데는 꽤 훌륭하다.

---

## Verilator vs NCVerilog

| 항목 | NCVerilog | Verilator |
|---|---|---|
| 비용 | 상용 (고가) | 무료 오픈소스 |
| CI 환경 사용 | 어려움 (라이선스) | 가능 (GitHub Actions) |
| 지원 언어 | Verilog, SystemVerilog, VHDL | Verilog, SystemVerilog (일부 제한) |
| 시뮬레이션 속도 | 보통 | 매우 빠름 (C++ 컴파일 후 실행) |
| 파형 포맷 | VCD, FSDB | VCD, FST |
| SVA Assertion | 지원 | 제한적 |

두 환경이 같은 소스를 공유한다는 것이 핵심이다.  
NCVerilog로 개발·디버그하고, Verilator로 CI를 돌린다.  
로컬에서는 편한 도구를 쓰고, 원격에서는 반복 가능한 도구를 쓰는 식이다. 실용적이고, 무엇보다 팀원 설득이 쉽다.

---

## Verilator 테스트벤치 구조

Verilator는 Verilog를 C++로 변환해서 컴파일한다.  
따라서 시뮬레이션 드라이버를 C++로 작성해야 한다.  
처음 보면 "왜 갑자기 C++까지?" 싶지만, 한 번 구조를 잡아두면 이후엔 꽤 담백하게 유지된다.

```
design/tb_verilator/
├── tb_top_verilator.sv  ← SystemVerilog 최상위 (DUT + Fake Memory 포함)
├── tb_dpi.cpp           ← C++ 시뮬레이션 드라이버
├── run.sh               ← Verilator 빌드 + 실행 스크립트
└── README.md
```

SystemVerilog DPI(Direct Programming Interface)로 C++과 SystemVerilog가 통신한다.

```systemverilog
// tb_top_verilator.sv
// DPI 함수로 클록과 리셋을 C++에서 제어
import "DPI-C" function bit tb_dpi_get_clk();
import "DPI-C" function bit tb_dpi_get_rst_n();

always @(*) clk   = tb_dpi_get_clk();
always @(*) rst_n = tb_dpi_get_rst_n();
```

C++ 드라이버에서 클록을 생성하고, 테스트 완료 신호를 받는다.

```cpp
// tb_dpi.cpp (핵심 루프)
while (!context.gotFinish()) {
    // Rising edge
    g_clk = 1;
    context.timeInc(kHalfPeriodNs);   // 5ns
    top->eval();
    trace->dump(context.time());

    // Falling edge
    g_clk = 0;
    context.timeInc(kHalfPeriodNs);   // 5ns

    // Reset release at t=80ns
    if (context.time() >= kResetReleaseNs)
        g_rst_n = 1;

    top->eval();
    trace->dump(context.time());
}

trace->close();
return context.gotFinish() ? 0 : 1;
```

---

## run.sh — 빌드와 실행을 한 번에

```bash
#!/usr/bin/env bash
# design/tb_verilator/run.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/../rtl"
OUT_DIR="${SCRIPT_DIR}/out"
mkdir -p "$OUT_DIR"

# 1. Verilator: SystemVerilog → C++ 변환
verilator \
  --cc \
  --exe \
  --trace-fst \
  --timing \
  -Wno-WIDTH -Wno-CASEINCOMPLETE \
  -I"${RTL_DIR}/inc" \
  "${SCRIPT_DIR}/tb_top_verilator.sv" \
  "${SCRIPT_DIR}/tb_dpi.cpp" \
  --top-module tb_top_verilator \
  -CFLAGS "-O2" \
  -o "${OUT_DIR}/sim" \
  2>&1 | tee "${OUT_DIR}/verilator_build.log"

# 2. C++ 컴파일 + 링크
make -C obj_dir -f Vtb_top_verilator.mk 2>&1 | tee -a "${OUT_DIR}/verilator_build.log"

# 3. 시뮬레이션 실행
"${OUT_DIR}/sim" 2>&1 | tee "${OUT_DIR}/verilator_console.log"
```

---

## GitHub Actions 워크플로우

```yaml
# .github/workflows/verilator_ci.yml
name: Verilator Smoke Test

on:
  push:
    paths:
      - 'design/rtl/**'
      - 'design/tb_verilator/**'
      - 'host_software/**'

jobs:
  simulate:
    name: Verilator 5.043 / GCC 11 / Ubuntu 22.04
    runs-on: ubuntu-22.04

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Install system dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y git autoconf flex bison gcc-11 g++-11 make

      # Verilator를 캐싱해서 매번 빌드하지 않도록
      - name: Cache Verilator 5.043 build
        id: cache-verilator
        uses: actions/cache@v4
        with:
          path: ~/verilator-install
          key: verilator-5.043-ubuntu-22.04-gcc11

      - name: Build Verilator 5.043
        if: steps.cache-verilator.outputs.cache-hit != 'true'
        run: |
          git clone --depth 1 --branch v5.043 \
            https://github.com/verilator/verilator /tmp/verilator
          cd /tmp/verilator
          autoconf && ./configure --prefix="$HOME/verilator-install"
          make -j$(nproc) && make install

      - name: Run Verilator simulation
        run: |
          cd design/tb_verilator
          chmod +x run.sh && ./run.sh

      # 실패해도 아티팩트는 항상 저장
      - name: Upload simulation artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: sim-artifacts-${{ github.run_id }}
          path: |
            design/tb_verilator/out/verilator_console.log
            design/tb_verilator/out/dump.fst
          retention-days: 7
```

> [IMG] **[그림 9-1]** *GitHub Actions에서 워크플로우가 성공적으로 완료된 화면*  
> *각 단계(Install, Cache, Build, Simulate)에 체크마크가 표시되고 총 실행 시간이 보인다*

---

## 워크플로우 설계의 핵심 결정들

### 1. 트리거 경로 제한

```yaml
on:
  push:
    paths:
      - 'design/rtl/**'
      - 'design/tb_verilator/**'
```

RTL이나 테스트벤치가 바뀔 때만 실행된다.  
문서(doc/, spec/, book/)를 수정할 때는 실행되지 않는다.  
불필요한 CI 실행을 줄여 GitHub Actions 무료 크레딧을 절약한다.  
CI도 공짜일 때 가장 예민하게 아껴 쓰게 되는 법이다.

### 2. Verilator 빌드 캐싱

Verilator를 소스에서 빌드하면 10분 이상 걸린다.  
`actions/cache@v4`로 빌드 결과물을 캐싱하면 두 번째 실행부터 30초 이내로 줄어든다.  
한 번 캐시를 맛보면, 캐시 없는 CI로 돌아가기가 꽤 어렵다. 인간은 원래 빠른 것에 쉽게 적응한다.

```yaml
key: verilator-5.043-ubuntu-22.04-gcc11
```

버전을 포함한 캐시 키를 쓰면, Verilator 버전을 바꿀 때 자동으로 재빌드된다.

### 3. 아티팩트 항상 저장

```yaml
if: always()
```

실패한 경우에도 로그와 파형 파일을 저장한다.  
CI가 실패했을 때 원인을 분석할 수 있어야 한다.

---

## CI 구축 프롬프트

**사용자 →**
```
.github/workflows/verilator_ci.yml을 작성해줘.

요구사항:
- Verilator 5.043 버전 고정
- Ubuntu 22.04에서 실행
- Verilator 빌드 결과를 캐싱해서 재빌드 방지
- design/rtl, design/tb_verilator 변경 시에만 트리거
- 시뮬레이션 실패해도 로그 파일은 artifact로 저장
- dump.fst 파형 파일도 저장 (7일 보관)
```

이 프롬프트 하나로 완성된 워크플로우 파일이 나왔다.  
GitHub Actions의 문법, 캐싱 전략, 아티팩트 설정이 모두 포함된 상태로.

---

## CI가 가져다주는 것

CI를 구축하고 나서 개발 사이클이 달라진다.  
체감상 가장 큰 변화는 심리적 안정감이다. "내가 뭘 망가뜨렸나?"를 혼자 짐작하는 대신, 파이프라인이 객관적으로 대답해준다.

```
코드 수정 → git push → [자동] 빌드 + 시뮬레이션 → 결과 확인
```

> [IMG] **[그림 9-2]** *VSCode Source Control 패널에서 commit + push 후 GitHub PR 체크 상태 표시*  
> *"All checks passed" 또는 "1 check failed" 배지가 표시된다*

이것이 하드웨어 개발에서 갖는 의미:  
- 어떤 모듈을 수정해도, 기존 테스트가 여전히 통과하는지 자동으로 확인된다
- 리그레션을 두려워하지 않고 리팩토링할 수 있다
- 다른 사람이 코드를 보내도 검증을 자동화할 수 있다

---

*다음 장: 10장 — 다른 AI를 리뷰어로 부르다*
