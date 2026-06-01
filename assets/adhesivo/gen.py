#!/usr/bin/env python3
"""
gen.py — Generador del logo adhesivo Tony's.

Pipeline:
  1. Dibuja el logo (casita + TONY'S) con Pillow + font TrueType bold real.
     - Casita: polígonos geometricos (icono simple, no necesita font)
     - "TONY'S": Impact o Arial Black del sistema Windows
  2. Threshold + Floyd-Steinberg para impresión térmica fiel.
  3. Genera:
       - logo-tonys-S.png        (1bpp B/W, 184×36)
       - logo-tonys-S.hex        (TSPL2 BITMAP hex)
       - logo-tonys-S.b64        (base64 dataURI)
       - logo-tonys-S-preview-4x.png (inspección humana 4×)

Determinístico: mismo input → mismo bitmap. Si la font cambia, el bitmap
cambia y queda registrado en git.
"""
import base64
import io
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent

# ── Carga spec.json ─────────────────────────────────────────────
with open(ROOT / 'spec.json', encoding='utf-8') as f:
    SPEC = json.load(f)

W = SPEC['logo']['ancho_dots']  # 184
H = SPEC['logo']['alto_dots']   # 36

# ── Font del sistema (preferencia: Impact > Arial Black > Arial Bold) ──
FONT_CANDIDATES = [
    ('C:/Windows/Fonts/impact.ttf', 38),       # Impact narrow → buena densidad
    ('C:/Windows/Fonts/arialbd.ttf', 34),      # Arial Bold
    ('C:/Windows/Fonts/tahomabd.ttf', 34),     # Tahoma Bold
    ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 34),  # Linux fallback
]


def cargar_font():
    """Carga la primera font disponible. None si ninguna existe."""
    for path, size in FONT_CANDIDATES:
        if Path(path).exists():
            return ImageFont.truetype(path, size), Path(path).name
    return ImageFont.load_default(), 'PIL_default'


def dibujar_casita(draw: ImageDraw.ImageDraw, x: int, y: int) -> None:
    """Casita isotipo 32×33 dots dibujada con polígonos puros.

    Diseño:
      - Techo triangular ancho
      - Cuerpo rectangular
      - Puerta arqueada (rect grande) — central
      - 2 ventanas chicas a los lados
    """
    # Techo (triángulo isósceles ancho)
    draw.polygon([
        (x + 16, y + 0),      # cima
        (x + 0,  y + 13),     # base izq
        (x + 32, y + 13),     # base der
    ], fill=0)
    # Alero (línea horizontal gruesa)
    draw.rectangle([x + 0, y + 12, x + 32, y + 16], fill=0)
    # Cuerpo
    draw.rectangle([x + 3, y + 16, x + 29, y + 33], fill=0)
    # Puerta (hueco blanco)
    draw.rectangle([x + 12, y + 22, x + 20, y + 33], fill=255)
    # Ventana izquierda
    draw.rectangle([x + 6, y + 19, x + 10, y + 22], fill=255)
    # Ventana derecha
    draw.rectangle([x + 22, y + 19, x + 26, y + 22], fill=255)


def construir_logo() -> Image.Image:
    """Construye el logo final 184×36 en modo '1' (1bpp B/W)."""
    font, font_name = cargar_font()
    print(f'[font] using {font_name}')

    # Trabajamos en grayscale 'L' para que threshold/dither tengan
    # un origen suave (anti-aliased fonts producen grises).
    img = Image.new('L', (W, H), color=255)
    draw = ImageDraw.Draw(img)

    # ── Casita @ (4, 2) — 32×33 dots ──
    dibujar_casita(draw, x=4, y=2)

    # ── "TONY'S" @ x=42 — con font truetype real ──
    # Centramos verticalmente la altura visual del texto.
    texto = "TONY'S"
    # Pillow >=10 usa textbbox; legacy usa textsize. Usamos getbbox del font.
    try:
        bbox = font.getbbox(texto)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        baseline_offset = bbox[1]  # cuánto sube la coord top respecto a bbox
    except AttributeError:
        tw, th = draw.textsize(texto, font=font)
        baseline_offset = 0

    # Posición: x=42 (después de la casita + margen), y ajustado para centrar
    text_x = 42
    text_y = (H - th) // 2 - baseline_offset
    draw.text((text_x, text_y), texto, fill=0, font=font)

    # Threshold suave + Floyd-Steinberg.
    # Threshold 140: el anti-alias gris < 140 cae a negro, > 140 a blanco.
    # Más agresivo que 128 → preserva trazos finos de la font.
    bw = img.point(lambda v: 0 if v < 140 else 255, mode='L')
    bw = bw.convert('1', dither=Image.FLOYDSTEINBERG)
    return bw


def imagen_a_tspl_hex(img: Image.Image) -> str:
    """Convierte imagen 1bpp a hex TSPL2 BITMAP.

    Formato TSPL2 BITMAP: bytes row-major, MSB-first, packed 8 pixels/byte.
    Convención bits TSPL2: 0=negro (impreso), 1=blanco.
    PIL mode '1':           0=negro,           255=blanco.
    """
    if img.mode != '1':
        img = img.convert('1')
    w, h = img.size
    if w % 8 != 0:
        raise ValueError(f'Ancho {w} no multiplo de 8 - TSPL2 requiere bytes alineados')
    bytes_per_row = w // 8
    px = img.load()
    out = []
    for y in range(h):
        for bx in range(bytes_per_row):
            byte = 0
            for bit in range(8):
                x = bx * 8 + bit
                pixel_white = px[x, y] != 0
                if pixel_white:
                    byte |= (1 << (7 - bit))
            out.append(byte)
    return ''.join(f'{b:02X}' for b in out)


def imagen_a_b64_dataurl(img: Image.Image) -> str:
    """Codifica PNG a base64 dataURI."""
    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    b64 = base64.b64encode(buf.getvalue()).decode('ascii')
    return f'data:image/png;base64,{b64}'


def main():
    img = construir_logo()

    png_path = ROOT / SPEC['logo']['archivo_png']
    img.save(png_path, format='PNG', optimize=True)
    print(f'[OK]PNG     ->{png_path.name} ({img.size[0]}x{img.size[1]}, {png_path.stat().st_size}B)')

    hex_str = imagen_a_tspl_hex(img)
    hex_path = ROOT / SPEC['logo']['archivo_hex']
    hex_path.write_text(hex_str, encoding='ascii')
    print(f'[OK]HEX     ->{hex_path.name} ({len(hex_str)} chars, {len(hex_str)//2} bytes)')

    b64_url = imagen_a_b64_dataurl(img)
    b64_path = ROOT / SPEC['logo']['archivo_b64']
    b64_path.write_text(b64_url, encoding='ascii')
    print(f'[OK]B64     ->{b64_path.name} ({len(b64_url)} chars)')

    preview = img.resize((W * 4, H * 4), Image.NEAREST)
    preview_path = ROOT / 'logo-tonys-S-preview-4x.png'
    preview.save(preview_path, format='PNG')
    print(f'[OK]PREVIEW ->{preview_path.name} ({W*4}x{H*4})')


if __name__ == '__main__':
    main()
