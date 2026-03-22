from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT_DIR = ROOT / "renders"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

APP_FONT = ROOT.parent.parent / "WorkoutApp" / "Resources" / "Fonts" / "PlayfairDisplaySC-Bold.ttf"
UI_FONT = Path("C:/Windows/Fonts/segoeui.ttf")
UI_FONT_BOLD = Path("C:/Windows/Fonts/segoeuib.ttf")
UI_FONT_LIGHT = Path("C:/Windows/Fonts/segoeuil.ttf")

BOARD_SIZE = (1600, 2000)
CARD_SIZE = (620, 740)
CARD_RADIUS = 42


def rgba(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4)) + (alpha,)


def load_font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int, int], bottom: tuple[int, int, int, int]) -> Image.Image:
    image = Image.new("RGBA", size)
    width, height = size
    pixels = image.load()
    for y in range(height):
        mix = y / max(height - 1, 1)
        row = tuple(int(top[index] + (bottom[index] - top[index]) * mix) for index in range(4))
        for x in range(width):
            pixels[x, y] = row
    return image


def diagonal_shine(size: tuple[int, int], opacity: int, blur: int, shift: int = 0) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    width, height = size
    draw.polygon(
        [
            (width * 0.08 + shift, -height * 0.1),
            (width * 0.52 + shift, -height * 0.1),
            (width * 0.22 + shift, height * 1.1),
            (-width * 0.12 + shift, height * 1.1),
        ],
        fill=(255, 255, 255, opacity),
    )
    return layer.filter(ImageFilter.GaussianBlur(blur))


def add_blob(target: Image.Image, bbox: tuple[float, float, float, float], color: tuple[int, int, int, int], blur: int) -> None:
    layer = Image.new("RGBA", target.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(bbox, fill=color)
    target.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def add_stroke_glow(
    target: Image.Image,
    points: tuple[tuple[int, int], ...],
    color: tuple[int, int, int, int],
    width: int,
    blur: int,
) -> None:
    layer = Image.new("RGBA", target.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.line(points, fill=color, width=width, joint="curve")
    target.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def draw_text_block(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
    x: int,
    y: int,
    max_width: int,
    line_gap: int = 8,
) -> int:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        test = word if not current else f"{current} {word}"
        if draw.textlength(test, font=font) <= max_width:
            current = test
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)

    cursor = y
    for line in lines:
        draw.text((x, cursor), line, font=font, fill=fill)
        line_box = font.getbbox(line)
        cursor += (line_box[3] - line_box[1]) + line_gap
    return cursor


def pill(
    image: Image.Image,
    box: tuple[int, int, int, int],
    fill_color: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
    text: str,
    font: ImageFont.FreeTypeFont,
    text_color: tuple[int, int, int, int],
) -> None:
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill=fill_color, outline=outline, width=2)
    text_width = draw.textlength(text, font=font)
    text_height = font.getbbox(text)[3] - font.getbbox(text)[1]
    x = box[0] + ((box[2] - box[0]) - text_width) / 2
    y = box[1] + ((box[3] - box[1]) - text_height) / 2 - 2
    draw.text((x, y), text, font=font, fill=text_color)


def draw_icon(draw: ImageDraw.ImageDraw, kind: str, x: int, y: int, size: int, color: tuple[int, int, int, int]) -> None:
    if kind == "programs":
        line = 4
        draw.rounded_rectangle((x + 6, y + 14, x + size - 6, y + size - 12), radius=14, outline=color, width=line)
        draw.line((x + 20, y + 30, x + size - 20, y + 30), fill=color, width=line)
        draw.line((x + 20, y + 48, x + size - 28, y + 48), fill=color, width=line)
        draw.line((x + 20, y + 66, x + size - 36, y + 66), fill=color, width=line)
    elif kind == "workout":
        line = 5
        draw.line((x + 8, y + size // 2, x + size - 8, y + size // 2), fill=color, width=line)
        draw.rounded_rectangle((x + 12, y + 20, x + 24, y + size - 20), radius=6, fill=color)
        draw.rounded_rectangle((x + size - 24, y + 20, x + size - 12, y + size - 20), radius=6, fill=color)
        draw.rounded_rectangle((x + 28, y + 28, x + 42, y + size - 28), radius=6, fill=color)
        draw.rounded_rectangle((x + size - 42, y + 28, x + size - 28, y + size - 28), radius=6, fill=color)
    elif kind == "statistics":
        line = 5
        points = [
            (x + 12, y + size - 18),
            (x + 28, y + size - 34),
            (x + 48, y + size - 28),
            (x + 66, y + 22),
            (x + size - 10, y + 12),
        ]
        draw.line(points, fill=color, width=line, joint="curve")
        for px, py in points:
            draw.ellipse((px - 5, py - 5, px + 5, py + 5), fill=color)
    elif kind == "profile":
        line = 4
        draw.ellipse((x + 24, y + 10, x + size - 24, y + 42), outline=color, width=line)
        draw.arc((x + 10, y + 34, x + size - 10, y + size - 6), 200, 340, fill=color, width=line)


def draw_chart(image: Image.Image, box: tuple[int, int, int, int], line_color: tuple[int, int, int, int], fill_color: tuple[int, int, int, int]) -> None:
    draw = ImageDraw.Draw(image)
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    line_layer = ImageDraw.Draw(overlay)
    x1, y1, x2, y2 = box
    points = [
        (x1 + 18, y2 - 38),
        (x1 + 76, y2 - 58),
        (x1 + 138, y2 - 112),
        (x1 + 216, y2 - 92),
        (x1 + 282, y2 - 168),
        (x2 - 20, y2 - 206),
    ]
    fill_points = [(x1 + 18, y2 - 2), *points, (x2 - 20, y2 - 2)]
    line_layer.polygon(fill_points, fill=fill_color)
    image.alpha_composite(overlay.filter(ImageFilter.GaussianBlur(10)))
    draw.line(points, fill=line_color, width=5, joint="curve")
    for px, py in points:
        draw.ellipse((px - 6, py - 6, px + 6, py + 6), fill=(255, 255, 255, 230))


@dataclass(frozen=True)
class SectionContent:
    key: str
    section: str
    title: str
    subtitle: str
    body: str
    cta: str
    details: tuple[str, ...]


@dataclass(frozen=True)
class GlowBlob:
    bbox: tuple[float, float, float, float]
    color: tuple[int, int, int, int]
    blur: int


@dataclass(frozen=True)
class GlowStroke:
    points: tuple[tuple[int, int], ...]
    color: tuple[int, int, int, int]
    width: int
    blur: int


@dataclass(frozen=True)
class SpectralGlowConfig:
    blobs: tuple[GlowBlob, ...]
    strokes: tuple[GlowStroke, ...] = ()
    base_shine_opacity: int = 18
    base_shine_blur: int = 46
    base_shine_shift: int = 0
    shine_opacity: int = 22
    shine_blur: int = 68
    shine_shift: int = -10
    orb_tint: tuple[int, int, int, int] = (139, 228, 255, 58)


SECTIONS = (
    SectionContent(
        key="programs",
        section="PROGRAMS",
        title="Starter Program",
        subtitle="2 workouts ready this week",
        body="Upper A and Lower A stay visible as a clean archive instead of a dense list.",
        cta="Open archive",
        details=("Upper A  •  4 exercises", "Lower A  •  3 exercises", "Fresh split  •  Strength focus"),
    ),
    SectionContent(
        key="workout",
        section="WORKOUT",
        title="Upper A In Progress",
        subtitle="3 of 4 exercises completed",
        body="The active card pushes live context first: timer, rest, and the next working set.",
        cta="Continue session",
        details=("42:18 active", "01:28 rest", "Next: Bench Press 72.5 kg"),
    ),
    SectionContent(
        key="statistics",
        section="STATISTICS",
        title="Bench Press Trend",
        subtitle="+12% working weight this month",
        body="A liquid chart surface keeps stats prominent without looking like a standard analytics tile.",
        cta="View history",
        details=("72.5 kg top set", "42 total sets", "4 sessions tracked"),
    ),
    SectionContent(
        key="profile",
        section="PROFILE",
        title="Profile Snapshot",
        subtitle="Core body metrics within reach",
        body="Profile uses the same glass shell but shifts toward a calmer, more personal settings tone.",
        cta="Edit metrics",
        details=("Age 27", "Weight 74 kg", "Height 179 cm"),
    ),
)


LEGACY_SPECTRAL_GLOW_CONFIG = SpectralGlowConfig(
    blobs=(
        GlowBlob((200, 520, 720, 920), rgba("#5ED8FF", 120), 96),
        GlowBlob((300, 560, 860, 960), rgba("#73F6C7", 76), 110),
        GlowBlob((420, 430, 760, 760), rgba("#8B72FF", 72), 96),
        GlowBlob((60, 180, 260, 360), rgba("#FFFFFF", 18), 54),
    ),
    base_shine_opacity=26,
    base_shine_blur=38,
    base_shine_shift=0,
    shine_opacity=36,
    shine_blur=52,
    shine_shift=-10,
    orb_tint=rgba("#8BE4FF", 74),
)


SPECTRAL_GLOW_CONFIGS: dict[str, SpectralGlowConfig] = {
    "programs": SpectralGlowConfig(
        blobs=(
            GlowBlob((40, 560, 500, 900), rgba("#62E0FF", 82), 128),
            GlowBlob((160, 590, 700, 920), rgba("#74F0CB", 56), 140),
            GlowBlob((70, 170, 250, 330), rgba("#FFFFFF", 10), 70),
        ),
        base_shine_opacity=16,
        base_shine_blur=50,
        base_shine_shift=12,
        orb_tint=rgba("#8BE4FF", 60),
    ),
    "workout": SpectralGlowConfig(
        blobs=(
            GlowBlob((330, 470, 760, 900), rgba("#6BDCFF", 58), 118),
            GlowBlob((420, 520, 820, 930), rgba("#8A79FF", 52), 126),
            GlowBlob((500, 610, 820, 930), rgba("#7BF4CC", 40), 132),
        ),
        strokes=(
            GlowStroke(((170, 560), (310, 610), (470, 690), (620, 790)), rgba("#66DEFF", 42), 126, 84),
        ),
        base_shine_opacity=15,
        base_shine_blur=52,
        base_shine_shift=88,
        shine_opacity=20,
        shine_blur=74,
        shine_shift=8,
        orb_tint=rgba("#B4C2FF", 50),
    ),
    "statistics": SpectralGlowConfig(
        blobs=(
            GlowBlob((180, 520, 720, 900), rgba("#5FD8FF", 44), 132),
            GlowBlob((330, 410, 760, 820), rgba("#8E7BFF", 52), 120),
            GlowBlob((80, 190, 240, 320), rgba("#FFFFFF", 8), 74),
        ),
        strokes=(
            GlowStroke(((86, 650), (198, 622), (316, 548), (430, 575), (548, 470)), rgba("#7F8BFF", 44), 102, 72),
            GlowStroke(((130, 700), (252, 664), (370, 592), (490, 608), (590, 520)), rgba("#66E0FF", 32), 82, 76),
        ),
        base_shine_opacity=12,
        base_shine_blur=56,
        base_shine_shift=46,
        shine_opacity=18,
        shine_blur=76,
        shine_shift=-24,
        orb_tint=rgba("#B8C3FF", 48),
    ),
    "profile": SpectralGlowConfig(
        blobs=(
            GlowBlob((120, 260, 530, 700), rgba("#82E4FF", 42), 150),
            GlowBlob((160, 320, 470, 610), rgba("#FFFFFF", 16), 120),
            GlowBlob((170, 520, 650, 880), rgba("#73EED0", 26), 144),
        ),
        base_shine_opacity=10,
        base_shine_blur=58,
        base_shine_shift=26,
        shine_opacity=16,
        shine_blur=82,
        shine_shift=-6,
        orb_tint=rgba("#D7F4FF", 34),
    ),
}


def board_background(size: tuple[int, int], accent: tuple[int, int, int, int]) -> Image.Image:
    base = vertical_gradient(size, rgba("#05070B"), rgba("#0A0D12"))
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    add_blob(glow, (-180, -120, 760, 520), rgba("#54D9F7", 46), 120)
    add_blob(glow, (880, -80, 1600, 520), rgba("#9677FF", 58), 100)
    add_blob(glow, (220, 1240, 1320, 2040), accent, 140)
    add_blob(glow, (1060, 900, 1760, 1700), rgba("#62F5C7", 44), 120)
    base.alpha_composite(glow)
    base.alpha_composite(diagonal_shine(size, opacity=18, blur=90))
    return base


def glass_base(
    size: tuple[int, int],
    outer_color: tuple[int, int, int, int],
    inner_color: tuple[int, int, int, int],
    shine_opacity: int = 26,
    shine_blur: int = 38,
    shine_shift: int = 0,
) -> Image.Image:
    layer = vertical_gradient(size, outer_color, inner_color)
    layer.alpha_composite(diagonal_shine(size, opacity=shine_opacity, blur=shine_blur, shift=shine_shift))
    return layer


def apply_card_shell(card: Image.Image, border: tuple[int, int, int, int], inner_border: tuple[int, int, int, int]) -> None:
    draw = ImageDraw.Draw(card)
    draw.rounded_rectangle((0, 0, card.width - 1, card.height - 1), radius=CARD_RADIUS, outline=border, width=2)
    draw.rounded_rectangle((10, 10, card.width - 11, card.height - 11), radius=CARD_RADIUS - 10, outline=inner_border, width=1)


def draw_header_orb(card: Image.Image, content: SectionContent, tint: tuple[int, int, int, int]) -> None:
    orb = Image.new("RGBA", card.size, (0, 0, 0, 0))
    add_blob(orb, (36, 32, 136, 132), tint, 28)
    card.alpha_composite(orb)
    draw = ImageDraw.Draw(card)
    draw.ellipse((40, 36, 136, 132), fill=rgba("#10151B", 182), outline=rgba("#FFFFFF", 45), width=2)
    draw_icon(draw, content.key, 56, 52, 64, rgba("#F6F7FB", 238))


def render_spectral_card(content: SectionContent, glow_config: SpectralGlowConfig = LEGACY_SPECTRAL_GLOW_CONFIG) -> Image.Image:
    card = glass_base(
        CARD_SIZE,
        rgba("#0E1218", 198),
        rgba("#080B10", 214),
        shine_opacity=glow_config.base_shine_opacity,
        shine_blur=glow_config.base_shine_blur,
        shine_shift=glow_config.base_shine_shift,
    )
    mask = rounded_mask(CARD_SIZE, CARD_RADIUS)
    card.putalpha(mask)

    accents = Image.new("RGBA", CARD_SIZE, (0, 0, 0, 0))
    for blob in glow_config.blobs:
        add_blob(accents, blob.bbox, blob.color, blob.blur)
    for stroke in glow_config.strokes:
        add_stroke_glow(accents, stroke.points, stroke.color, stroke.width, stroke.blur)
    card.alpha_composite(accents)
    card.alpha_composite(
        diagonal_shine(
            CARD_SIZE,
            opacity=glow_config.shine_opacity,
            blur=glow_config.shine_blur,
            shift=glow_config.shine_shift,
        )
    )
    apply_card_shell(card, rgba("#EEF2FF", 156), rgba("#FFFFFF", 46))
    draw_header_orb(card, content, glow_config.orb_tint)

    draw = ImageDraw.Draw(card)
    small = load_font(UI_FONT_BOLD, 18)
    title = load_font(UI_FONT_BOLD, 60)
    subtitle = load_font(UI_FONT, 28)
    body = load_font(UI_FONT, 22)
    body_bold = load_font(UI_FONT_BOLD, 22)

    draw.text((52, 164), content.section, font=small, fill=rgba("#B2B9C6", 214))
    y = draw_text_block(draw, content.title, title, rgba("#FBFDFF", 255), 52, 198, 510, 2)
    draw.text((52, y + 12), content.subtitle, font=subtitle, fill=rgba("#D9E4F3", 222))
    y = draw_text_block(draw, content.body, body, rgba("#CDD5E0", 196), 52, y + 68, 500, 10)

    start_y = y + 26
    for index, detail in enumerate(content.details):
        row_y = start_y + index * 42
        draw.text((52, row_y), "•", font=body_bold, fill=rgba("#EAF7FF", 210))
        draw.text((74, row_y), detail, font=body, fill=rgba("#E4ECF8", 210))

    pill(card, (52, 650, 264, 700), rgba("#EEF6FF", 26), rgba("#F7FAFF", 88), content.cta, load_font(UI_FONT_BOLD, 20), rgba("#FDFEFF", 255))
    return card


def render_refined_spectral_card(content: SectionContent) -> Image.Image:
    return render_spectral_card(content, SPECTRAL_GLOW_CONFIGS[content.key])


def draw_module(image: Image.Image, box: tuple[int, int, int, int], title: str, value: str, accent: tuple[int, int, int, int]) -> None:
    module = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(module)
    draw.rounded_rectangle(box, radius=28, fill=rgba("#10151C", 112), outline=rgba("#FFFFFF", 36), width=2)
    add_blob(module, (box[0] - 20, box[1] - 10, box[2] + 30, box[3] + 18), accent, 32)
    image.alpha_composite(module)
    draw = ImageDraw.Draw(image)
    caption_font = load_font(UI_FONT, 16)
    value_font = load_font(UI_FONT_BOLD, 26)
    draw.text((box[0] + 18, box[1] + 14), title, font=caption_font, fill=rgba("#B6BECB", 220))
    draw.text((box[0] + 18, box[1] + 38), value, font=value_font, fill=rgba("#FCFDFF", 255))


def render_orbit_card(content: SectionContent) -> Image.Image:
    card = glass_base(CARD_SIZE, rgba("#0E1118", 188), rgba("#0A0D12", 222))
    mask = rounded_mask(CARD_SIZE, CARD_RADIUS)
    card.putalpha(mask)

    accents = Image.new("RGBA", CARD_SIZE, (0, 0, 0, 0))
    add_blob(accents, (380, 40, 700, 320), rgba("#A587FF", 116), 72)
    add_blob(accents, (332, 68, 600, 296), rgba("#66E7FF", 106), 84)
    add_blob(accents, (20, 520, 360, 860), rgba("#53D1FF", 76), 92)
    add_blob(accents, (220, 560, 620, 930), rgba("#79FFC9", 66), 110)
    card.alpha_composite(accents)
    card.alpha_composite(diagonal_shine(CARD_SIZE, opacity=24, blur=42, shift=50))
    apply_card_shell(card, rgba("#F5F7FF", 136), rgba("#FFFFFF", 44))

    draw = ImageDraw.Draw(card)
    header_font = load_font(UI_FONT_BOLD, 18)
    title_font = load_font(UI_FONT_BOLD, 48)
    subtitle_font = load_font(UI_FONT, 24)
    body_font = load_font(UI_FONT, 20)

    pill(card, (42, 40, 176, 84), rgba("#F1F4FF", 24), rgba("#FFFFFF", 60), content.section, load_font(UI_FONT_BOLD, 16), rgba("#EFF4FD", 236))
    draw.ellipse((450, 54, 560, 164), fill=rgba("#0F141C", 168), outline=rgba("#FFFFFF", 48), width=2)
    draw_icon(draw, content.key, 474, 78, 60, rgba("#FFFFFF", 240))

    y = draw_text_block(draw, content.title, title_font, rgba("#FCFDFF", 255), 42, 128, 420, 2)
    draw.text((42, y + 8), content.subtitle, font=subtitle_font, fill=rgba("#D5DEEA", 212))
    draw_text_block(draw, content.body, body_font, rgba("#C7D0DB", 190), 42, y + 56, 520, 8)

    if content.key == "programs":
        draw_module(card, (42, 458, 282, 580), "Primary split", "Upper A", rgba("#67DBFF", 56))
        draw_module(card, (298, 458, 578, 580), "Lower body", "Lower A", rgba("#8F82FF", 54))
        draw_module(card, (42, 598, 578, 692), "Library", "2 workouts, 7 exercises", rgba("#73FFC6", 38))
    elif content.key == "workout":
        draw_module(card, (42, 458, 282, 580), "Live timer", "42:18", rgba("#67DBFF", 58))
        draw_module(card, (298, 458, 578, 580), "Rest", "01:28", rgba("#8F82FF", 56))
        draw_module(card, (42, 598, 578, 692), "Next set", "Bench Press  72.5 kg x 6", rgba("#73FFC6", 42))
    elif content.key == "statistics":
        draw_module(card, (42, 458, 282, 580), "Best set", "72.5 kg", rgba("#67DBFF", 56))
        draw_module(card, (298, 458, 578, 580), "Delta", "+12%", rgba("#8F82FF", 56))
        draw_chart(card, (52, 594, 568, 694), rgba("#F8FAFF", 244), rgba("#66E5FF", 42))
    else:
        draw_module(card, (42, 458, 282, 580), "Weight", "74 kg", rgba("#67DBFF", 56))
        draw_module(card, (298, 458, 578, 580), "Height", "179 cm", rgba("#8F82FF", 56))
        draw_module(card, (42, 598, 578, 692), "Language", "English / Русский", rgba("#73FFC6", 40))

    pill(card, (404, 40, 576, 84), rgba("#FFFFFF", 16), rgba("#FFFFFF", 50), content.cta, load_font(UI_FONT_BOLD, 18), rgba("#FDFEFF", 245))
    return card


def render_prism_card(content: SectionContent) -> Image.Image:
    card = glass_base(CARD_SIZE, rgba("#10141B", 194), rgba("#090C11", 228))
    mask = rounded_mask(CARD_SIZE, CARD_RADIUS)
    card.putalpha(mask)

    accents = Image.new("RGBA", CARD_SIZE, (0, 0, 0, 0))
    add_blob(accents, (24, 24, 360, 320), rgba("#6EEAFF", 64), 80)
    add_blob(accents, (320, 120, 720, 460), rgba("#9372FF", 74), 92)
    add_blob(accents, (120, 520, 680, 920), rgba("#8DFFD2", 66), 120)
    card.alpha_composite(accents)
    card.alpha_composite(diagonal_shine(CARD_SIZE, opacity=28, blur=40, shift=-40))
    apply_card_shell(card, rgba("#F4F7FF", 146), rgba("#FFFFFF", 42))
    draw_header_orb(card, content, rgba("#FFFFFF", 26))

    inner = Image.new("RGBA", CARD_SIZE, (0, 0, 0, 0))
    inner_draw = ImageDraw.Draw(inner)
    inner_draw.rounded_rectangle((32, 150, 588, 708), radius=34, fill=rgba("#0D1218", 112), outline=rgba("#FFFFFF", 34), width=2)
    add_blob(inner, (300, 360, 680, 720), rgba("#67DEFF", 46), 84)
    card.alpha_composite(inner)

    draw = ImageDraw.Draw(card)
    section_font = load_font(UI_FONT_BOLD, 17)
    title_font = load_font(UI_FONT_BOLD, 42)
    subtitle_font = load_font(UI_FONT, 22)
    body_font = load_font(UI_FONT, 19)
    metric_font = load_font(UI_FONT_BOLD, 28)
    metric_label = load_font(UI_FONT, 16)

    draw.text((54, 162), content.section, font=section_font, fill=rgba("#C7D0DA", 210))
    y = draw_text_block(draw, content.title, title_font, rgba("#FCFDFF", 255), 54, 192, 500, 2)
    draw.text((54, y + 6), content.subtitle, font=subtitle_font, fill=rgba("#D2DCE8", 216))
    draw_text_block(draw, content.body, body_font, rgba("#C4CDD9", 190), 54, y + 48, 500, 7)

    if content.key == "statistics":
        draw_chart(card, (72, 404, 548, 560), rgba("#FBFDFF", 250), rgba("#63DEFF", 38))
        metrics = [("Peak", "72.5"), ("Month", "+12"), ("Sets", "42")]
    elif content.key == "workout":
        metrics = [("Timer", "42:18"), ("Rest", "01:28"), ("Sets", "9/12")]
        pill(card, (72, 408, 548, 456), rgba("#F2F7FF", 16), rgba("#FFFFFF", 50), "Bench Press  •  72.5 kg target", load_font(UI_FONT_BOLD, 18), rgba("#FCFEFF", 242))
        pill(card, (72, 474, 548, 522), rgba("#EFFFF8", 14), rgba("#FFFFFF", 46), "Current focus  •  steady tempo + full lockout", load_font(UI_FONT, 17), rgba("#EFFAF4", 228))
    elif content.key == "profile":
        metrics = [("Age", "27"), ("Weight", "74"), ("Height", "179")]
        pill(card, (72, 408, 548, 456), rgba("#F2F7FF", 16), rgba("#FFFFFF", 50), "English / Русский", load_font(UI_FONT_BOLD, 18), rgba("#FCFEFF", 242))
        pill(card, (72, 474, 548, 522), rgba("#EFFFF8", 14), rgba("#FFFFFF", 46), "Backup status  •  ready", load_font(UI_FONT, 17), rgba("#EFFAF4", 228))
    else:
        metrics = [("Plans", "2"), ("Live", "1"), ("Focus", "A/B")]
        pill(card, (72, 408, 548, 456), rgba("#F2F7FF", 16), rgba("#FFFFFF", 50), "Upper A + Lower A", load_font(UI_FONT_BOLD, 18), rgba("#FCFEFF", 242))
        pill(card, (72, 474, 548, 522), rgba("#EFFFF8", 14), rgba("#FFFFFF", 46), "Archive first  •  fast open  •  minimal clutter", load_font(UI_FONT, 17), rgba("#EFFAF4", 228))

    metric_boxes = [(72, 594, 214, 674), (238, 594, 380, 674), (404, 594, 546, 674)]
    for (label, value), box in zip(metrics, metric_boxes):
        draw.rounded_rectangle(box, radius=24, fill=rgba("#10161E", 120), outline=rgba("#FFFFFF", 36), width=2)
        draw.text((box[0] + 16, box[1] + 12), label, font=metric_label, fill=rgba("#B9C2CC", 216))
        draw.text((box[0] + 16, box[1] + 32), value, font=metric_font, fill=rgba("#FCFDFF", 255))

    pill(card, (406, 52, 576, 96), rgba("#F3F7FF", 16), rgba("#FFFFFF", 50), content.cta, load_font(UI_FONT_BOLD, 18), rgba("#FDFEFF", 242))
    return card


def place_card(board: Image.Image, card: Image.Image, x: int, y: int) -> None:
    shadow = Image.new("RGBA", board.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle((x + 16, y + 24, x + card.width + 24, y + card.height + 34), radius=CARD_RADIUS + 10, fill=(0, 0, 0, 150))
    board.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(32)))
    board.alpha_composite(card, dest=(x, y))


def render_board(
    filename: str,
    headline: str,
    note: str,
    accent: tuple[int, int, int, int],
    renderer: Callable[[SectionContent], Image.Image],
) -> Path:
    board = board_background(BOARD_SIZE, accent)
    draw = ImageDraw.Draw(board)
    board_title = load_font(APP_FONT, 54)
    board_subtitle = load_font(UI_FONT, 24)
    section_font = load_font(UI_FONT_BOLD, 18)

    draw.text((110, 88), headline, font=board_title, fill=rgba("#F7FAFF", 245))
    draw.text((110, 160), note, font=board_subtitle, fill=rgba("#C2CAD7", 220))
    draw.text((1110, 118), "LIQUID GLASS CARD STUDY", font=section_font, fill=rgba("#D4DBE6", 210))

    positions = [(110, 270), (870, 270), (110, 1070), (870, 1070)]
    for content, (x, y) in zip(SECTIONS, positions):
        place_card(board, renderer(content), x, y)

    output = OUTPUT_DIR / filename
    board.save(output, format="PNG")
    return output


def main() -> None:
    outputs = [
        render_board(
            "01-spectral-pool.png",
            "Direction 01  •  Spectral Pool",
            "Closest to the reference silhouette: clean outline, pooled glow at the bottom, colder liquid glass instead of orange heat.",
            rgba("#63DBFF", 60),
            render_spectral_card,
        ),
        render_board(
            "02-orbit-layers.png",
            "Direction 02  •  Orbit Layers",
            "A more futuristic route with floating modules and a brighter liquid core. Better if cards should feel active and premium.",
            rgba("#8A79FF", 64),
            render_orbit_card,
        ),
        render_board(
            "03-prism-dashboard.png",
            "Direction 03  •  Prism Dashboard",
            "The most product-oriented direction: stronger information framing inside the glass shell while keeping the same rim treatment.",
            rgba("#7CF0D0", 58),
            render_prism_card,
        ),
        render_board(
            "04-spectral-section-glows.png",
            "Direction 04  •  Spectral Refined",
            "Same rim and layout as Direction 01, with quieter inner light and distinct section-specific glow signatures.",
            rgba("#5EDCFF", 56),
            render_refined_spectral_card,
        ),
    ]

    for output in outputs:
        print(output)


if __name__ == "__main__":
    main()
