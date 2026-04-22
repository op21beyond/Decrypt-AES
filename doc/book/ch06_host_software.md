# 6장 — 레퍼런스 소프트웨어를 만들다

---

## 왜 소프트웨어가 먼저인가

하드웨어 IP를 검증하려면 **정답 데이터**가 필요하다.  
테스트벤치는 "IP가 올바른 출력을 내보냈는가"를 확인해야 하는데,  
"올바른 출력"이 무엇인지 알려면 소프트웨어 레퍼런스 구현이 있어야 한다.

즉, RTL을 믿기 전에 먼저 비교할 기준을 만들어야 한다.  
검증의 세계에서는 "느낌상 맞는 것 같다"가 가장 비싼 문장이다.

RTL과 소프트웨어가 동일한 입력에 대해 동일한 출력을 내면, RTL이 맞다.  
이 원칙이 `host_software/`의 존재 이유다.

```
host_software/
├── aes128_ctr.c/.h    ← Pure C AES-128 CTR 구현 (레퍼런스)
├── crc32.c/.h         ← Pure C CRC-32 구현 (레퍼런스)
├── aes_decrypt_ip.c/.h ← IP 레지스터 드라이버
├── test_vectors.h     ← 테스트 입력/출력 벡터
├── tc_params.h        ← 테스트 케이스 파라미터
├── sw_test.c          ← 레퍼런스 SW만으로 검증
└── ip_test.c          ← IP 드라이버를 사용한 검증
```

---

## Pure C 레퍼런스 구현

**사용자 →**
```
host_software/aes128_ctr.c와 aes128_ctr.h를 작성해줘.
AES-128 CTR 모드 순수 소프트웨어 구현이야.

요구사항:
- 특정 CPU 가정 없이 generic하게 작성 (embedded 환경 고려)
- NIST SP 800-38A 표준 준수
- 헤더 포맷: Nonce(96-bit) + Initial Counter(32-bit)
- 카운터는 big-endian, 32-bit wrap
- hw 구현과 byte-for-byte 동일한 결과를 내야 함
```

생성된 코드의 핵심 부분은 비교적 교과서적이다.  
이런 종류의 코드는 화려함보다 해석 가능성이 중요하다. "잘 돌아간다"보다 "왜 이렇게 돌았는지 읽힌다"가 더 값지다.

```c
/* aes128_ctr.c — CTR 모드 블록 처리 */
void aes128_ctr_crypt(
    const uint8_t key[16],
    const uint8_t nonce[12],   /* 96-bit nonce */
    uint32_t      initial_ctr, /* 32-bit initial counter */
    const uint8_t *in,
    uint8_t       *out,
    size_t         len)
{
    uint8_t  counter_block[16];
    uint8_t  keystream[16];
    uint32_t ctr = initial_ctr;

    /* Counter block 구성: nonce(12B) || counter(4B, big-endian) */
    memcpy(counter_block, nonce, 12);

    while (len > 0) {
        /* Big-endian counter 삽입 */
        counter_block[12] = (uint8_t)(ctr >> 24);
        counter_block[13] = (uint8_t)(ctr >> 16);
        counter_block[14] = (uint8_t)(ctr >>  8);
        counter_block[15] = (uint8_t)(ctr      );

        /* AES Encrypt(counter_block) → keystream */
        aes128_encrypt_block(key, counter_block, keystream);

        /* XOR with input */
        size_t block_len = (len < 16) ? len : 16;
        for (size_t i = 0; i < block_len; i++)
            out[i] = in[i] ^ keystream[i];

        in  += block_len;
        out += block_len;
        len -= block_len;
        ctr++;   /* 32-bit wrap은 자동 */
    }
}
```

---

## IP 드라이버 구조

IP 드라이버는 **플랫폼 독립적(generic)** 으로 설계했다.  
레지스터 접근 함수를 함수 포인터로 주입받는 방식이다.

```c
/* aes_decrypt_ip.h — 드라이버 컨텍스트 */
typedef struct {
    uint32_t  base_addr;   /* IP 레지스터 베이스 주소 */
    uint32_t  ring_phys;   /* Descriptor 링 버퍼 물리 주소 */
    uint32_t  ring_size;   /* 링 버퍼 슬롯 수 */
    uint32_t  tail;        /* 현재 tail 포인터 */

    /* 플랫폼 별로 제공하는 레지스터 접근 함수 */
    void     (*reg_write)(uint32_t base, uint32_t offset, uint32_t val);
    uint32_t (*reg_read) (uint32_t base, uint32_t offset);
} aes_ip_ctx_t;
```

이 구조 덕분에 동일한 드라이버 코드가:
- 시뮬레이션 환경에서는 테스트벤치 레지스터 접근 함수를 사용하고,
- 실제 SoC에서는 MMIO 접근 함수를 사용할 수 있다.

한마디로, 드라이버가 특정 보드나 특정 런타임에 묶이지 않는다.  
초기 프로젝트에서 이런 추상화를 해두면 나중에 "이거 왜 테스트벤치에서만 되죠?" 같은 질문을 줄일 수 있다.

초기화 함수:

```c
int aes_ip_init(aes_ip_ctx_t *ctx,
                uint32_t max_rd_out, uint32_t max_wr_out)
{
    /* 엔진이 STOP 상태인지 확인 */
    uint32_t st = rreg(ctx, AES_IP_REG_STATUS)
                  & AES_IP_STATUS_STATE_MASK;
    if (st != AES_IP_STATE_STOP)
        return -1;

    /* 링 버퍼 설정 */
    wreg(ctx, AES_IP_REG_CMD_BUF_ADDR, ctx->ring_phys);
    wreg(ctx, AES_IP_REG_CMD_BUF_SIZE, ctx->ring_size);
    wreg(ctx, AES_IP_REG_CMD_TAIL_PTR, 0u);
    ctx->tail = 0u;

    /* AXI outstanding 제한 설정 (1-16 범위로 클램프) */
    uint32_t rd = (max_rd_out < 1u) ? 1u :
                  (max_rd_out > 16u) ? 16u : max_rd_out;
    uint32_t wr = (max_wr_out < 1u) ? 1u :
                  (max_wr_out > 16u) ? 16u : max_wr_out;
    wreg(ctx, AES_IP_REG_AXI_OUTSTAND,
         (rd << AES_IP_OUTSTAND_RD_SHIFT) |
         (wr << AES_IP_OUTSTAND_WR_SHIFT));

    return 0;
}
```

---

## 테스트 벡터 생성

테스트 데이터는 Pure C 코드로 직접 생성했다. 키, nonce, plaintext를 정하고, 암호화해서 ciphertext를 만들고, CRC를 계산한다.  
손으로 만들 수도 있겠지만, 그 방식은 보통 두 번째 케이스쯤부터 사람의 집중력을 시험하기 시작한다.

**사용자 →**
```
test_vectors.h를 작성해줘.
AES-128 CTR 모드로 암호화된 테스트 데이터가 담겨야 해.

테스트 케이스:
1. 단순 케이스: 32바이트 plaintext (패딩 없음)
2. 패딩 케이스: 40바이트 plaintext (8바이트 패딩)
3. CRC 오류 케이스: 올바른 ciphertext지만 CRC 값이 틀림

모든 값은 C 배열로, 주석으로 바이트 의미를 설명해줘.
```

```c
/* test_vectors.h — 테스트 케이스 1 */
static const uint8_t TC1_KEY[16] = {
    0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
    0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
};  /* AES-128 NIST test key */

static const uint8_t TC1_NONCE[12] = {
    0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7,
    0xf8, 0xf9, 0xfa, 0xfb
};  /* 96-bit nonce */

static const uint32_t TC1_INITIAL_CTR = 0xfc000001u;

static const uint8_t TC1_PLAINTEXT[32] = { /* ... */ };
static const uint8_t TC1_CIPHERTEXT[32] = { /* ... */ };
static const uint32_t TC1_CRC32 = 0xA1B2C3D4u;  /* CRC over ciphertext */
```

---

## 드라이버와 사양서 사이의 교차 검증

드라이버를 작성하면서 사양서에 모호한 부분이 발견되기도 했다.

예를 들어, AES 키를 쓸 때 byte order가 명확하지 않았다.

**발견된 모호함:**
```
사양서 5.9: "AES_KEY_0 holds key bits [31:0]"
그런데 key[0]이 LSB인가, MSB인가?
```

**Claude에게 확인 →**
```
aes_decrypt_ip.c의 aes_ip_write_key 함수에서
키 바이트 순서를 어떻게 해야 하는지 명확히 해줘.
RTL의 aes128_key_sched.v와 바이트 순서가 일치해야 해.
```

**Claude 답변 →**
```
RTL aes128_key_sched.v를 확인해보면:
    assign round_keys[31:0] = aes_key[31:0];  // = AES_KEY_0

즉 AES_KEY_0의 [31:0]이 키의 최하위 32비트입니다.
key[0]은 LSB, 즉 little-endian입니다.

드라이버에서:
    w = key[0] | (key[1]<<8) | (key[2]<<16) | (key[3]<<24);
    wreg(AES_KEY_0, w);
```

이런 교차 검증이 드라이버 작성 과정에서 자연스럽게 이루어졌다.  
흥미로운 점은, 문서 하나를 쓰는 일처럼 보여도 실제로는 사양서와 RTL과 드라이버가 서로를 교정하고 있다는 것이다.  
RTL과 드라이버가 같은 AI에 의해 만들어졌기 때문에 의도한 바이트 순서도 일관되게 유지됐고, 사람이 그 연결을 확인하면서 신뢰도를 높일 수 있었다.

---

## 소프트웨어 개발이 RTL 개발에 미치는 영향

Pure C 레퍼런스를 먼저 완성하고 나니, 테스트 데이터도 준비됐고, 예상 출력도 생겼다.  
이 순간부터 프로젝트는 "설계를 시작했다"에서 "이제 틀린 걸 잡아낼 수 있다" 단계로 넘어간다.  
이것이 다음 단계인 시뮬레이션 환경 구축의 기반이 된다.

```
sw_test.c가 검증하는 것: 소프트웨어 AES + CRC 구현의 정확성
ip_test.c가 검증하는 것: IP 드라이버 + IP 동작의 정확성

두 결과가 일치하면 IP가 올바르다.
```

---

*다음 장: 7장 — 검증 환경을 구축하다*
