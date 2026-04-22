#!/usr/bin/env bash
# =============================================================================
# build.sh — 「AI한테 칩 설계 시켜봤다」 출판 파일 빌드 스크립트
# =============================================================================
set -euo pipefail

BOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${BOOK_DIR}/out"
mkdir -p "$OUT_DIR"

# 챕터 순서
CHAPTERS=(
    "${BOOK_DIR}/ch00_prologue.md"
    "${BOOK_DIR}/ch01_first_prompt.md"
    "${BOOK_DIR}/ch02_spec_writing.md"
    "${BOOK_DIR}/ch03_pivot.md"
    "${BOOK_DIR}/ch04_project_structure.md"
    "${BOOK_DIR}/ch05_rtl_vibe_coding.md"
    "${BOOK_DIR}/ch06_host_software.md"
    "${BOOK_DIR}/ch07_testbench.md"
    "${BOOK_DIR}/ch08_bug_fixing.md"
    "${BOOK_DIR}/ch09_verilator_ci.md"
    "${BOOK_DIR}/ch10_codex_review.md"
    "${BOOK_DIR}/ch11_epilogue.md"
)

MIKTEX_BIN="/c/Users/op21b/AppData/Local/Programs/MiKTeX/miktex/bin/x64"
export PATH="$MIKTEX_BIN:$PATH"

TITLE_MD="${BOOK_DIR}/title.md"
TITLE_MD_NOCOVER="${BOOK_DIR}/title-nocover.md"
TITLE="vibe-coding-rtl"

echo "=========================================="
echo " Build: ${TITLE}"
echo " Output: ${OUT_DIR}"
echo "=========================================="

# ------------------------------------------------------------------
# 1. DOCX (Microsoft Word)
# ------------------------------------------------------------------
echo ""
echo "[1/3] Generating DOCX..."
pandoc \
    "${TITLE_MD}" \
    "${CHAPTERS[@]}" \
    --output="${OUT_DIR}/${TITLE}.docx" \
    --from=markdown \
    --to=docx \
    --toc \
    --toc-depth=2 \
    --highlight-style=tango \
    2>&1

if [ -f "${OUT_DIR}/${TITLE}.docx" ]; then
    echo "  ✓ DOCX → ${OUT_DIR}/${TITLE}.docx"
else
    echo "  ✗ DOCX 생성 실패"
fi

# ------------------------------------------------------------------
# 2. EPUB
# ------------------------------------------------------------------
echo ""
echo "[2/3] Generating EPUB..."
pandoc \
    "${TITLE_MD}" \
    "${CHAPTERS[@]}" \
    --output="${OUT_DIR}/${TITLE}.epub" \
    --from=markdown \
    --to=epub3 \
    --toc \
    --toc-depth=2 \
    --highlight-style=tango \
    --split-level=1 \
    --epub-cover-image="${BOOK_DIR}/assets/cover.png" \
    2>&1

if [ -f "${OUT_DIR}/${TITLE}.epub" ]; then
    echo "  ✓ EPUB → ${OUT_DIR}/${TITLE}.epub"
else
    echo "  ✗ EPUB 생성 실패"
fi

# ------------------------------------------------------------------
# 3. PDF — XeLaTeX (MiKTeX, 고품질 조판)
# ------------------------------------------------------------------
echo ""
echo "[3/3] Generating PDF (via XeLaTeX)..."
pandoc \
    "${TITLE_MD_NOCOVER}" \
    "${CHAPTERS[@]}" \
    --output="${OUT_DIR}/${TITLE}.pdf" \
    --from=markdown \
    --pdf-engine=xelatex \
    --include-in-header="${BOOK_DIR}/latex-header.tex" \
    --include-before-body="${BOOK_DIR}/cover-page.tex" \
    --toc \
    --toc-depth=2 \
    --highlight-style=tango \
    -V colorlinks=true \
    -V linkcolor=blue \
    -V urlcolor=blue \
    2>&1 | grep -v "major issue" || true

if [ -f "${OUT_DIR}/${TITLE}.pdf" ]; then
    echo "  ✓ PDF  → ${OUT_DIR}/${TITLE}.pdf"
else
    echo "  ✗ XeLaTeX PDF 생성 실패"
fi

# ------------------------------------------------------------------
# 완료
# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo " 완료"
ls -lh "${OUT_DIR}/" 2>/dev/null | grep -E "\.(docx|epub|pdf)$" || true
echo "=========================================="
