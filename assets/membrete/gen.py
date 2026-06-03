#!/usr/bin/env python3
"""
gen.py — Generador de logos para membretes.

Genera 3 logos en 184×36 dots @ 203 DPI:
  - logo-tonys-S       (envasado · ya existe en /assets/adhesivo/, lo replicamos acá por consistencia)
  - logo-tienda-ME-S   (membrete ME · góndola tienda)
  - logo-almacen-WH-S  (membrete WH · andamio almacén)

Cada uno genera:
  - <name>.png       (1bpp B/W)
  - <name>.hex       (TSPL2 BITMAP)
  - <name>.b64       (base64 dataURI)
  - <name>-preview-4x.png (inspección)

Pipeline determinístico — mismo input → mismo output bit a bit.
"""
import base64
import io
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
W = 184
H = 36

FONT_CANDIDATES = [
    ('C:/Windows/Fonts/impact.ttf', 38),
    ('C:/Windows/Fonts/arialbd.ttf', 34),
    ('C:/Windows/Fonts/tahomabd.ttf', 34),
    ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 34),
]


def cargar_font():
    for path, size in FONT_CANDIDATES:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


# ───────── ICONOS GEOMÉTRICOS para los tres logos ─────────

def dibujar_casita(draw, x, y):
    """Casita TONY'S (envasado)."""
    draw.polygon([(x + 14, y + 0), (x + 0, y + 12), (x + 28, y + 12)], fill=0)
    draw.rectangle([x + 0, y + 12, x + 32, y + 16], fill=0)
    draw.rectangle([x + 3, y + 16, x + 29, y + 33], fill=0)
    draw.rectangle([x + 12, y + 22, x + 20, y + 33], fill=255)
    draw.rectangle([x + 6, y + 19, x + 10, y + 22], fill=255)
    draw.rectangle([x + 22, y + 19, x + 26, y + 22], fill=255)


def dibujar_tienda(draw, x, y):
    """Tienda — góndola con techo a dos aguas + cartel/marquesina."""
    # Marquesina (techo plano arriba)
    draw.rectangle([x + 0, y + 0, x + 32, y + 6], fill=0)
    # Pico decorativo del techo
    draw.polygon([(x + 12, y + 0), (x + 16, y - 2), (x + 20, y + 0)], fill=0)
    # Cuerpo del frente
    draw.rectangle([x + 2, y + 6, x + 30, y + 33], fill=0)
    # Vidriera grande (hueco blanco)
    draw.rectangle([x + 5, y + 10, x + 27, y + 22], fill=255)
    # Cruceta en la vidriera (marco)
    draw.rectangle([x + 15, y + 10, x + 17, y + 22], fill=0)
    draw.rectangle([x + 5, y + 15, x + 27, y + 17], fill=0)
    # Puerta abajo
    draw.rectangle([x + 13, y + 24, x + 19, y + 33], fill=255)


def dibujar_caja_almacen(draw, x, y):
    """Almacén — caja apilada con líneas que sugieren stack."""
    # Caja principal
    draw.rectangle([x + 0, y + 8, x + 32, y + 33], fill=0)
    # Tapa superior con líneas
    draw.polygon([(x + 0, y + 8), (x + 6, y + 2), (x + 32, y + 2), (x + 32, y + 8)], fill=0)
    draw.line([(x + 6, y + 2), (x + 6, y + 33)], fill=255, width=1)
    # Cinta horizontal
    draw.rectangle([x + 0, y + 18, x + 32, y + 22], fill=255)
    # Cinta vertical
    draw.rectangle([x + 14, y + 8, x + 18, y + 33], fill=255)
    # Pliegue (línea oblicua en la tapa)
    draw.line([(x + 18, y + 2), (x + 18, y + 8)], fill=255, width=1)


# ───────── LETRAS ─────────

def dibujar_texto(draw, texto, x_inicio, y, font):
    """Dibuja texto con TrueType, retorna ancho aproximado."""
    try:
        bbox = font.getbbox(texto)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        baseline_offset = bbox[1]
    except AttributeError:
        tw, th = draw.textsize(texto, font=font)
        baseline_offset = 0
    text_y = (H - th) // 2 - baseline_offset
    draw.text((x_inicio, text_y), texto, fill=0, font=font)
    return tw


def construir_logo(variante):
    """variante: 'envasado' | 'tienda_me' | 'almacen_wh'"""
    img = Image.new('L', (W, H), color=255)
    draw = ImageDraw.Draw(img)
    font = cargar_font()

    if variante == 'envasado':
        dibujar_casita(draw, x=4, y=2)
        dibujar_texto(draw, "TONY'S", x_inicio=42, y=0, font=font)
    elif variante == 'tienda_me':
        dibujar_tienda(draw, x=4, y=4)
        dibujar_texto(draw, "TIENDA", x_inicio=42, y=0, font=font)
    elif variante == 'almacen_wh':
        dibujar_caja_almacen(draw, x=4, y=2)
        dibujar_texto(draw, "ALMACEN", x_inicio=42, y=0, font=font)
    else:
        raise ValueError(f'Variante desconocida: {variante}')

    bw = img.point(lambda v: 0 if v < 128 else 255, mode='L')
    bw = bw.convert('1', dither=Image.NONE)
    return bw


def imagen_a_tspl_hex(img):
    if img.mode != '1':
        img = img.convert('1')
    w, h = img.size
    if w % 8 != 0:
        raise ValueError(f'Ancho {w} no multiplo de 8')
    bytes_per_row = w // 8
    px = img.load()
    out = []
    for y in range(h):
        for bx in range(bytes_per_row):
            byte = 0
            for bit in range(8):
                x = bx * 8 + bit
                if px[x, y] != 0:
                    byte |= (1 << (7 - bit))
            out.append(byte)
    return ''.join(f'{b:02X}' for b in out)


def imagen_a_b64(img):
    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode('ascii')


def generar_variante(nombre_base, variante):
    img = construir_logo(variante)
    png_path = ROOT / f'{nombre_base}.png'
    img.save(png_path, format='PNG', optimize=True)
    print(f'[OK] PNG     -> {png_path.name} ({W}x{H})')

    hex_str = imagen_a_tspl_hex(img)
    hex_path = ROOT / f'{nombre_base}.hex'
    hex_path.write_text(hex_str, encoding='ascii')
    print(f'[OK] HEX     -> {hex_path.name} ({len(hex_str)//2} bytes)')

    b64 = imagen_a_b64(img)
    b64_path = ROOT / f'{nombre_base}.b64'
    b64_path.write_text(b64, encoding='ascii')
    print(f'[OK] B64     -> {b64_path.name}')

    preview = img.resize((W * 4, H * 4), Image.NEAREST)
    pp = ROOT / f'{nombre_base}-preview-4x.png'
    preview.save(pp, format='PNG')
    print(f'[OK] PREVIEW -> {pp.name}')


def main():
    generar_variante('logo-tonys-S', 'envasado')
    print()
    generar_variante('logo-tienda-ME-S', 'tienda_me')
    print()
    generar_variante('logo-almacen-WH-S', 'almacen_wh')


if __name__ == '__main__':
    main()
