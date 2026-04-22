from pathlib import Path
from textwrap import dedent

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
ASSET_DIR = ROOT / "assets"
PNG_PATH = ASSET_DIR / "cover.png"
SVG_PATH = ASSET_DIR / "cover.svg"

WIDTH = 1800
HEIGHT = 2700


def load_font(size: int, bold: bool = False):
    candidates = []
    if bold:
        candidates += [
            "C:/Windows/Fonts/malgunbd.ttf",
            "C:/Windows/Fonts/NanumSquareEB.ttf",
            "C:/Windows/Fonts/NanumGothicBold.ttf",
        ]
    else:
        candidates += [
            "C:/Windows/Fonts/malgun.ttf",
            "C:/Windows/Fonts/NanumSquareR.ttf",
            "C:/Windows/Fonts/NanumGothic.ttf",
        ]

    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def hex_to_rgb(value: str):
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def draw_gradient(image: Image.Image, top: str, bottom: str):
    draw = ImageDraw.Draw(image)
    top_rgb = hex_to_rgb(top)
    bottom_rgb = hex_to_rgb(bottom)
    for y in range(HEIGHT):
        ratio = y / (HEIGHT - 1)
        color = tuple(
            int(top_rgb[i] * (1 - ratio) + bottom_rgb[i] * ratio) for i in range(3)
        )
        draw.line((0, y, WIDTH, y), fill=color)


def wrap_text(text: str, font: ImageFont.FreeTypeFont, max_width: int):
    words = text.split()
    lines = []
    current = ""
    dummy = Image.new("RGB", (10, 10))
    draw = ImageDraw.Draw(dummy)
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if draw.textbbox((0, 0), candidate, font=font)[2] <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def build_png():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    image = Image.new("RGB", (WIDTH, HEIGHT), "#0b1020")
    draw_gradient(image, "#07111f", "#1c0f2e")

    glow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse((1060, 120, 1740, 820), fill=(0, 214, 201, 80))
    glow_draw.ellipse((80, 1680, 920, 2550), fill=(255, 122, 61, 72))
    glow_draw.rounded_rectangle((170, 190, 1630, 2510), radius=72, outline=(255, 255, 255, 38), width=2)
    glow = glow.filter(ImageFilter.GaussianBlur(36))
    image = Image.alpha_composite(image.convert("RGBA"), glow)

    draw = ImageDraw.Draw(image)

    card_box = (150, 170, 1650, 2530)
    draw.rounded_rectangle(card_box, radius=64, fill=(8, 14, 27, 220), outline=(255, 255, 255, 40), width=2)

    # Decorative chip
    chip_box = (270, 320, 1530, 1220)
    draw.rounded_rectangle(chip_box, radius=56, fill="#0f1b31", outline="#7ef5ec", width=5)
    inner_chip = (360, 410, 1440, 1130)
    draw.rounded_rectangle(inner_chip, radius=40, fill="#13284a", outline="#9fd8ff", width=3)

    pin_color = "#98f6ef"
    for idx in range(11):
        x = 410 + idx * 95
        draw.rounded_rectangle((x, 270, x + 44, 320), radius=10, fill=pin_color)
        draw.rounded_rectangle((x, 1220, x + 44, 1270), radius=10, fill=pin_color)
    for idx in range(6):
        y = 485 + idx * 110
        draw.rounded_rectangle((220, y, 270, y + 46), radius=10, fill=pin_color)
        draw.rounded_rectangle((1530, y, 1580, y + 46), radius=10, fill=pin_color)

    trace = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    trace_draw = ImageDraw.Draw(trace)
    trace_draw.line((420, 770, 620, 770, 760, 620, 1060, 620), fill=(126, 245, 236, 180), width=10)
    trace_draw.line((1060, 620, 1180, 740, 1360, 740), fill=(126, 245, 236, 180), width=10)
    trace_draw.line((520, 980, 760, 980, 980, 860, 1280, 860), fill=(255, 144, 98, 170), width=10)
    trace_draw.line((440, 560, 620, 560, 760, 700), fill=(149, 213, 255, 170), width=8)
    trace = trace.filter(ImageFilter.GaussianBlur(2))
    image = Image.alpha_composite(image, trace)
    draw = ImageDraw.Draw(image)

    mono_font = load_font(74, bold=True)
    draw.text((445, 520), "VIBE", font=mono_font, fill="#d7fbff")
    draw.text((830, 520), "RTL", font=mono_font, fill="#ffb18c")
    draw.text((450, 640), "AES  CTR  AXI4  CI", font=load_font(40, bold=False), fill="#8edce5")
    draw.text((450, 845), "0100 0001 0100 1001", font=load_font(34, bold=False), fill="#9fd8ff")
    draw.text((450, 910), "chip.craft(ai_assisted=True)", font=load_font(34, bold=False), fill="#ffd2bf")

    title_font = load_font(138, bold=True)
    subtitle_font = load_font(54, bold=False)
    body_font = load_font(40, bold=False)
    label_font = load_font(34, bold=True)

    draw.text((230, 1420), "AI한테", font=title_font, fill="#f8fbff")
    draw.text((230, 1575), "칩 설계", font=title_font, fill="#86fff2")
    draw.text((230, 1730), "시켜봤다", font=title_font, fill="#ff9a69")

    subtitle = "하드웨어 엔지니어를 위한\n생각보다 현실적인 바이브코딩 실전 입문"
    draw.multiline_text((236, 1930), subtitle, font=subtitle_font, fill="#d5dfef", spacing=20)

    quote = "사양서부터 RTL, 테스트벤치, CI까지.\nAI와 함께 3일 만에 AES IP를 만든 기록."
    draw.multiline_text((236, 2148), quote, font=body_font, fill="#a9bdd7", spacing=16)

    draw.rounded_rectangle((236, 2360, 520, 2430), radius=18, fill="#102646", outline="#7ef5ec", width=2)
    draw.text((270, 2375), "SSVD SoC Team", font=label_font, fill="#d9ffff")
    draw.text((1180, 2380), "2026", font=label_font, fill="#d7dfed")

    image.convert("RGB").save(PNG_PATH, format="PNG", optimize=True)


def build_svg():
    svg = f"""\
<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-label="AI한테 칩 설계 시켜봤다 cover">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#07111f" />
      <stop offset="100%" stop-color="#1c0f2e" />
    </linearGradient>
    <filter id="blur40"><feGaussianBlur stdDeviation="40"/></filter>
    <filter id="blur8"><feGaussianBlur stdDeviation="8"/></filter>
  </defs>
  <rect width="{WIDTH}" height="{HEIGHT}" fill="url(#bg)"/>
  <ellipse cx="1400" cy="470" rx="340" ry="300" fill="#00d6c9" fill-opacity="0.28" filter="url(#blur40)"/>
  <ellipse cx="460" cy="2180" rx="360" ry="360" fill="#ff7a3d" fill-opacity="0.24" filter="url(#blur40)"/>
  <rect x="150" y="170" width="1500" height="2360" rx="64" fill="#080e1bd6" stroke="#ffffff33" stroke-width="2"/>
  <rect x="270" y="320" width="1260" height="900" rx="56" fill="#0f1b31" stroke="#7ef5ec" stroke-width="5"/>
  <rect x="360" y="410" width="1080" height="720" rx="40" fill="#13284a" stroke="#9fd8ff" stroke-width="3"/>
  <g fill="#98f6ef">
    <rect x="410" y="270" width="44" height="50" rx="10"/><rect x="505" y="270" width="44" height="50" rx="10"/><rect x="600" y="270" width="44" height="50" rx="10"/><rect x="695" y="270" width="44" height="50" rx="10"/><rect x="790" y="270" width="44" height="50" rx="10"/><rect x="885" y="270" width="44" height="50" rx="10"/><rect x="980" y="270" width="44" height="50" rx="10"/><rect x="1075" y="270" width="44" height="50" rx="10"/><rect x="1170" y="270" width="44" height="50" rx="10"/><rect x="1265" y="270" width="44" height="50" rx="10"/><rect x="1360" y="270" width="44" height="50" rx="10"/>
    <rect x="410" y="1220" width="44" height="50" rx="10"/><rect x="505" y="1220" width="44" height="50" rx="10"/><rect x="600" y="1220" width="44" height="50" rx="10"/><rect x="695" y="1220" width="44" height="50" rx="10"/><rect x="790" y="1220" width="44" height="50" rx="10"/><rect x="885" y="1220" width="44" height="50" rx="10"/><rect x="980" y="1220" width="44" height="50" rx="10"/><rect x="1075" y="1220" width="44" height="50" rx="10"/><rect x="1170" y="1220" width="44" height="50" rx="10"/><rect x="1265" y="1220" width="44" height="50" rx="10"/><rect x="1360" y="1220" width="44" height="50" rx="10"/>
    <rect x="220" y="485" width="50" height="46" rx="10"/><rect x="220" y="595" width="50" height="46" rx="10"/><rect x="220" y="705" width="50" height="46" rx="10"/><rect x="220" y="815" width="50" height="46" rx="10"/><rect x="220" y="925" width="50" height="46" rx="10"/><rect x="220" y="1035" width="50" height="46" rx="10"/>
    <rect x="1530" y="485" width="50" height="46" rx="10"/><rect x="1530" y="595" width="50" height="46" rx="10"/><rect x="1530" y="705" width="50" height="46" rx="10"/><rect x="1530" y="815" width="50" height="46" rx="10"/><rect x="1530" y="925" width="50" height="46" rx="10"/><rect x="1530" y="1035" width="50" height="46" rx="10"/>
  </g>
  <g fill="none" stroke-linecap="round" stroke-linejoin="round" filter="url(#blur8)">
    <path d="M420 770 H620 L760 620 H1060 L1180 740 H1360" stroke="#7ef5ec" stroke-opacity="0.8" stroke-width="10"/>
    <path d="M520 980 H760 L980 860 H1280" stroke="#ff9062" stroke-opacity="0.75" stroke-width="10"/>
    <path d="M440 560 H620 L760 700" stroke="#95d5ff" stroke-opacity="0.75" stroke-width="8"/>
  </g>
  <g font-family="'Malgun Gothic','NanumGothic','Apple SD Gothic Neo',sans-serif">
    <text x="445" y="520" font-size="74" font-weight="700" fill="#d7fbff">VIBE</text>
    <text x="830" y="520" font-size="74" font-weight="700" fill="#ffb18c">RTL</text>
    <text x="450" y="640" font-size="40" fill="#8edce5">AES  CTR  AXI4  CI</text>
    <text x="450" y="845" font-size="34" fill="#9fd8ff">0100 0001 0100 1001</text>
    <text x="450" y="910" font-size="34" fill="#ffd2bf">chip.craft(ai_assisted=True)</text>
    <text x="230" y="1520" font-size="138" font-weight="700" fill="#f8fbff">AI한테</text>
    <text x="230" y="1675" font-size="138" font-weight="700" fill="#86fff2">칩 설계</text>
    <text x="230" y="1830" font-size="138" font-weight="700" fill="#ff9a69">시켜봤다</text>
    <text x="236" y="1930" font-size="54" fill="#d5dfef">
      <tspan x="236" dy="0">하드웨어 엔지니어를 위한</tspan>
      <tspan x="236" dy="78">생각보다 현실적인 바이브코딩 실전 입문</tspan>
    </text>
    <text x="236" y="2148" font-size="40" fill="#a9bdd7">
      <tspan x="236" dy="0">사양서부터 RTL, 테스트벤치, CI까지.</tspan>
      <tspan x="236" dy="58">AI와 함께 3일 만에 AES IP를 만든 기록.</tspan>
    </text>
    <rect x="236" y="2360" width="284" height="70" rx="18" fill="#102646" stroke="#7ef5ec" stroke-width="2"/>
    <text x="270" y="2408" font-size="34" font-weight="700" fill="#d9ffff">SSVD SoC Team</text>
    <text x="1180" y="2406" font-size="34" font-weight="700" fill="#d7dfed">2026</text>
  </g>
</svg>
"""
    SVG_PATH.write_text(dedent(svg), encoding="utf-8")


if __name__ == "__main__":
    build_png()
    build_svg()
