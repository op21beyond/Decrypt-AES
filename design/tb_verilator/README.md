# tb_verilator — Verilator Simulation Testbench

AES Decryption Engine IP를 Verilator로 시뮬레이션하는 환경입니다.

---

## 디렉토리 구조

```
design/
├── tb/
│   ├── tb_defines.vh          ★ 공유 define 상수 (레지스터 오프셋, 메모리 맵 등)
│   ├── tb_core.sv             ★ 공유 TB 본체 (신호 선언, DUT/메모리 인스턴스, 태스크, 시나리오)
│   ├── tb_top.v               NCVerilog 래퍼 — 네이티브 클록/리셋 생성 + include tb_core.sv
│   ├── fake_mem.v             AXI4 메모리 모델 (NCVerilog/Verilator 공용)
│   └── gen_mem.c              mem_init.hex 생성기 (C99)
│
└── tb_verilator/
    ├── tb_top_verilator.sv    Verilator 래퍼 — DPI 클록/리셋 + include tb_core.sv
    ├── tb_dpi.cpp             C++ main: 클록/리셋 DPI 공급, VCD 기록
    ├── run.sh                 빌드 + 시뮬레이션 실행 스크립트
    ├── mem_init.hex           gen_mem 실행 후 자동 생성 (시뮬레이션 워킹 디렉토리에 위치)
    └── out/                   빌드/시뮬레이션 산출물 (자동 생성)
        ├── obj_dir/           Verilator 생성 C++ 코드 및 바이너리
        ├── dump.fst           시뮬레이션 파형
        └── verilator_console.log  시뮬레이션 stdout/stderr 캡처
```

### 파일 역할 분리 (★ 심볼)

| 파일 | NCVerilog | Verilator |
|------|-----------|-----------|
| `tb_defines.vh` | `include | `include |
| `tb_core.sv` | `include (tb_top.v 안에서) | `include (tb_top_verilator.sv 안에서) |
| `tb_top.v` | 톱 모듈 | 미사용 |
| `tb_top_verilator.sv` | 미사용 | 톱 모듈 |

시뮬레이터별 차이는 클록/리셋 공급 방식과 덤프 방식뿐이며,
실제 테스트 로직은 `tb_core.sv` 하나에만 존재합니다.

---

## 사전 요구사항

| 도구 | 최소 버전 | 비고 |
|------|-----------|------|
| Verilator | **5.0** 이상 (검증: 5.043) | `--timing` 플래그 필요 |
| GCC (C++) | **11** 이상 | C++20 코루틴 지원 필수 |
| GCC (C) | 7 이상 | `gen_mem.c` 빌드용 (C99) |
| GNU Make | 4 이상 | Verilator 내부 빌드에 사용 |

### Ubuntu 22.04 설치 예시

```bash
# 시스템 의존성
sudo apt-get install -y git autoconf flex bison help2man gcc-11 g++-11 make

# Verilator 5.043 소스 빌드 (배포판 패키지는 4.x)
git clone --depth 1 --branch v5.043 https://github.com/verilator/verilator
cd verilator
autoconf
./configure
make -j$(nproc)
sudo make install
```

버전 확인:

```bash
verilator --version   # Verilator 5.043 ...
g++ --version         # g++ (Ubuntu 11.x.x) 11.x.x ...
```

---

## 실행 방법

```bash
cd design/tb_verilator
chmod +x run.sh
./run.sh
```

### 클린 빌드

`out/` 디렉토리와 `gen_mem` 바이너리를 제거하고 처음부터 다시 빌드합니다.
(`mem_init.hex`는 소스 변경 시에만 재생성되며 클린 시 삭제되지 않습니다.)

```bash
./run.sh -clean
```

### 실행 흐름

1. 환경 체크 (verilator, gcc, g++, make, 버전, C++20 지원)
2. `gen_mem` 바이너리 빌드 (소스 변경 시에만)
3. `mem_init.hex` 생성 (메모리 이미지)
4. Verilator 컴파일 → `out/obj_dir/Vtb_top_verilator`
5. 시뮬레이션 실행 → `out/verilator_console.log`, `out/dump.fst`
6. 로그에서 `ALL TESTS PASSED` 유무 확인 → PASS / FAIL 출력 및 종료 코드

---

## 테스트 케이스

| TC | 설명 | 종료 조건 |
|----|------|-----------|
| TC0 | 1블록(16 B), 패딩 없음, CRC IEEE 802.3 | IRQ → PAUSE |
| TC1 | 3블록(48 B), 16 B 패딩, CRC-32C | IRQ → PAUSE |
| TC2 | 6블록(96 B), 32 B 패딩, CRC IEEE 802.3 | IRQ → PAUSE |
| TC3 | 3블록(48 B), 8 B 패딩, CRC-32C, CRC 오류, 링 랩어라운드 | last=1 → STOP |
| TC4 | 디스크립터 페치 시 SLVERR 주입 → BUS_ERROR 처리 | STOP + STATUS.BUS_ERROR=1 |
| TC5 | valid=0 디스크립터 → 백도어로 valid=1 설정 → 정상 처리 확인 | IMM_STOP |
| TC6 | 동작 중 CTRL_IMM_STOP 발행 → 즉시 정지 확인 | STOP |

기대 평문: 카운터 패턴 `pt[i] = i & 0xFF` (AES-128-CTR, NIST SP 800-38A F.5.1 키)

---

## 출력 파일

| 파일 | 내용 |
|------|------|
| `out/verilator_console.log` | `[PASS]` / `[FAIL]` 라인 포함 전체 시뮬레이션 로그 |
| `out/dump.fst` | 전체 계층 파형 — GTKWave 등으로 열람 |
| `out/obj_dir/` | Verilator 생성 C++ 코드 및 컴파일 산출물 |

```bash
gtkwave out/dump.fst &
```

---

## 동작 원리

Verilator는 `--timing` 플래그로 `@(posedge clk)` 등 타이밍 구문을 C++20 코루틴으로 변환합니다.
클록/리셋은 `tb_dpi.cpp`의 `main` 루프에서 DPI 함수를 통해 주입됩니다.

```
tb_dpi.cpp main loop
  g_clk = 0/1, g_rst_n 설정
  top->eval()
    └─ assign clk = tb_dpi_get_clk()   ← eval()마다 재평가 (DPI = volatile)
          └─ @(posedge clk) 코루틴 깨움 → 테스트 시나리오 (tb_core.sv) 진행
```

`rst_n`은 t=80 ns (낙하 엣지)에서 해제되며, NCVerilog 버전의
`@(negedge clk); rst_n = 1'b1` 동작과 동일합니다.

---

## 경고 정책

run.sh에서 억제하는 Verilator 경고 목록:

| 경고 코드 | 분류 | 이유 |
|-----------|------|------|
| `TIMESCALEMOD` | 반드시 무시 | 여러 소스 파일에 `timescale 선언 분산 — 기능적 무해 |
| `DECLFILENAME` | 반드시 무시 | `fake_mem.v`가 `tb/` 경로에 위치 — NCVerilog 공유 구조상 의도적 |
| `LITENDIAN` | 검토 후 수정 권장 | RTL `[0:N-1]` 벡터 → `[N-1:0]`으로 변환 가능한 것들은 수정 검토 |

`WIDTH`, `UNOPTFLAT`, `CASEINCOMPLETE`, `STMTDLY`는 억제하지 않으며
실제 RTL 문제로 간주하여 반드시 수정합니다.

---

## CI 연동

`.github/workflows/verilator_ci.yml`에 GitHub Actions 워크플로우가 포함되어 있습니다.

- **트리거**: `design/` 또는 `host_software/` 변경 시 push/PR 자동 실행
- **환경**: Ubuntu 22.04, Verilator 5.043 소스 빌드 (캐싱 적용), GCC 11
- **산출물**: `verilator_console.log`, `dump.fst` 7일간 보관

---

## 트러블슈팅

**`verilator: command not found`**  
Verilator 설치 경로가 `PATH`에 없습니다. `which verilator` 확인 후 `.bashrc`에 추가.

**`error: coroutine_traits is not a member of std`**  
GCC 11 미만이거나 `-std=c++20`이 적용되지 않은 경우입니다. `g++ --version` 확인.

**`$readmemh: file not found`**  
`mem_init.hex`가 없는 경우입니다. `./run.sh -clean`으로 재생성.

**시뮬레이션이 종료되지 않고 행**  
`out/verilator_console.log`에서 마지막 `[ERROR]` 라인을 확인.
타임아웃 500 ms 워치독이 발동되면 `[FATAL] Simulation timeout`이 출력됩니다.
