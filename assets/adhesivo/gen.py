#!/usr/bin/env python3
"""
gen.py — Generador del logo adhesivo Tony's.

Pipeline:
  1. Dibuja el logo (casita + TONY'S) DIRECTAMENTE con Pillow.
     No depende de cairosvg ni de fonts del sistema — todo es geometría
     pura para que el resultado sea idéntico en cualquier máquina.
  2. Aplica threshold 140 + dithering Floyd-Steinberg para impresión
     térmica fiel.
  3. Genera:
       - logo-tonys-S.png        (1bpp B/W, 180×36)
       - logo-tonys-S.hex        (TSPL2 BITMAP hex para Envasados.gs)
       - logo-tonys-S.b64        (base64 dataURI para frontend MOS)

Uso:
  python gen.py

Requisitos:
  pip install Pillow

Versionado:
  El bitmap generado es DETERMINÍSTICO — mismo input ->mismo output bit a bit.
  Esto permite versionar logo-tonys-S.{png,hex,b64} en git y detectar
  cualquier cambio accidental al regenerar.
"""
import base64
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent

# ── Carga spec.json ─────────────────────────────────────────────
with open(ROOT / 'spec.json', encoding='utf-8') as f:
    SPEC = json.load(f)

W = SPEC['logo']['ancho_dots']  # 180
H = SPEC['logo']['alto_dots']   # 36


def dibujar_casita(draw: ImageDraw.ImageDraw, x: int, y: int) -> None:
    """Casita isotipo 28×30 dots dibujada con polígonos puros."""
    # Techo (triángulo isósceles)
    draw.polygon([(x + 14, y + 0), (x + 0, y + 12), (x + 28, y + 12)], fill=0)
    # Cuerpo (rectángulo) — pega abajo del techo
    draw.rectangle([x + 2, y + 12, x + 26, y + 30], fill=0)
    # Puerta (hueco blanco centrado-bajo)
    draw.rectangle([x + 11, y + 19, x + 17, y + 30], fill=255)
    # Ventana izquierda (hueco blanco)
    draw.rectangle([x + 6, y + 15, x + 9, y + 18], fill=255)
    # Ventana derecha (hueco blanco)
    draw.rectangle([x + 19, y + 15, x + 22, y + 18], fill=255)


def letra_T(d, x, y, w=22, h=28):
    """T: barra horizontal arriba + columna central."""
    d.rectangle([x, y, x + w, y + 6], fill=0)
    d.rectangle([x + (w // 2) - 3, y, x + (w // 2) + 3, y + h], fill=0)


def letra_O(d, x, y, w=22, h=28):
    """O: marco rectangular con stroke 5."""
    d.rectangle([x, y, x + w, y + h], fill=0)
    d.rectangle([x + 5, y + 5, x + w - 5, y + h - 5], fill=255)


def letra_N(d, x, y, w=22, h=28):
    """N: dos columnas + diagonal."""
    # Columna izquierda
    d.rectangle([x, y, x + 5, y + h], fill=0)
    # Columna derecha
    d.rectangle([x + w - 5, y, x + w, y + h], fill=0)
    # Diagonal (línea gruesa pixel-by-pixel)
    for i in range(h):
        # interpola x desde 5 hasta w-5 mientras y desciende
        dx = 5 + int((w - 10) * i / h)
        d.rectangle([x + dx, y + i, x + dx + 5, y + i + 2], fill=0)


def letra_Y(d, x, y, w=22, h=28):
    """Y: dos diagonales superiores que se juntan en columna inferior."""
    half = h // 2
    # Diagonal izquierda (de top-izq a centro-medio)
    for i in range(half):
        dx = int((w / 2 - 3) * i / half)
        d.rectangle([x + dx, y + i, x + dx + 5, y + i + 2], fill=0)
    # Diagonal derecha (de top-der a centro-medio)
    for i in range(half):
        dx = w - 5 - int((w / 2 - 3) * i / half)
        d.rectangle([x + dx, y + i, x + dx + 5, y + i + 2], fill=0)
    # Columna inferior
    d.rectangle([x + (w // 2) - 3, y + half, x + (w // 2) + 3, y + h], fill=0)


def letra_apostrofe(d, x, y, w=8, h=28):
    """Apóstrofe: punto arriba que cuelga como coma."""
    d.rectangle([x + 2, y + 2, x + 6, y + 10], fill=0)


def letra_S(d, x, y, w=22, h=28):
    """S: tres barras horizontales + dos conectores."""
    # Barra superior
    d.rectangle([x, y, x + w, y + 5], fill=0)
    # Barra media
    d.rectangle([x, y + (h // 2) - 3, x + w, y + (h // 2) + 3], fill=0)
    # Barra inferior
    d.rectangle([x, y + h - 5, x + w, y + h], fill=0)
    # Conector vertical superior-izq
    d.rectangle([x, y, x + 5, y + (h // 2)], fill=0)
    # Conector vertical inferior-der
    d.rectangle([x + w - 5, y + (h // 2), x + w, y + h], fill=0)


LETRAS = {
    'T': letra_T, 'O': letra_O, 'N': letra_N, 'Y': letra_Y,
    "'": letra_apostrofe, 'S': letra_S
}


def dibujar_texto(draw: ImageDraw.ImageDraw, texto: str, x: int, y: int, spacing: int = 4) -> int:
    """Dibuja texto compuesto por letras geométricas. Retorna ancho total."""
    cur_x = x
    for ch in texto:
        fn = LETRAS.get(ch)
        if not fn:
            continue
        w = 8 if ch == "'" else 22
        fn(draw, cur_x, y, w, 28)
        cur_x += w + spacing
    return cur_x - x


def construir_logo() -> Image.Image:
    """Construye el logo final 180×36 en modo '1' (1bpp B/W)."""
    # Trabajamos en escala de grises ('L') para que threshold/dither tengan
    # un origen razonable. Después convertimos a '1' con FLOYDSTEINBERG.
    img = Image.new('L', (W, H), color=255)
    draw = ImageDraw.Draw(img)

    # Casita @ (2, 3) — 28×30 dots
    dibujar_casita(draw, x=2, y=3)

    # TONY'S @ (38, 4) — 28 dots de alto
    dibujar_texto(draw, "TONY'S", x=38, y=4, spacing=4)

    # Threshold + dither a 1bpp. Aunque el dibujo es ya 0/255 puro,
    # esto formaliza el contrato — cualquier futuro elemento gris
    # (sombras, anti-alias) se dithereará automáticamente.
    bw = img.point(lambda v: 0 if v < 140 else 255, mode='L')
    bw = bw.convert('1', dither=Image.FLOYDSTEINBERG)
    return bw


def imagen_a_tspl_hex(img: Image.Image) -> str:
    """Convierte imagen 1bpp a hex TSPL2 BITMAP.

    Formato TSPL2: bytes row-major, MSB-first, packed 8 pixels por byte.
    En TSPL2 BITMAP: 0=negro, 1=blanco (opposite to PNG mode '1' donde
    0=negro y 255=blanco).
    """
    if img.mode != '1':
        img = img.convert('1')
    w, h = img.size
    if w % 8 != 0:
        raise ValueError(f'Ancho {w} no múltiplo de 8 — TSPL2 requiere bytes alineados')
    bytes_per_row = w // 8
    px = img.load()
    out = []
    for y in range(h):
        for bx in range(bytes_per_row):
            byte = 0
            for bit in range(8):
                x = bx * 8 + bit
                # PIL mode '1': 0=negro, 255=blanco
                # TSPL2 BITMAP: 0=negro (impreso), 1=blanco
                # ->invertimos: si pixel PIL=0 ->bit=0 (negro impreso)
                pixel_white = px[x, y] != 0
                if pixel_white:
                    byte |= (1 << (7 - bit))
            out.append(byte)
    return ''.join(f'{b:02X}' for b in out)


def imagen_a_b64_dataurl(img: Image.Image) -> str:
    """Codifica PNG a base64 dataURI para uso directo en CSS/HTML."""
    import io
    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    b64 = base64.b64encode(buf.getvalue()).decode('ascii')
    return f'data:image/png;base64,{b64}'


def main():
    img = construir_logo()

    # PNG
    png_path = ROOT / SPEC['logo']['archivo_png']
    img.save(png_path, format='PNG', optimize=True)
    print(f'[OK]PNG     ->{png_path.name} ({img.size[0]}x{img.size[1]}, {png_path.stat().st_size}B)')

    # Hex TSPL2
    hex_str = imagen_a_tspl_hex(img)
    hex_path = ROOT / SPEC['logo']['archivo_hex']
    hex_path.write_text(hex_str, encoding='ascii')
    print(f'[OK]HEX     ->{hex_path.name} ({len(hex_str)} chars, {len(hex_str)//2} bytes)')

    # Base64 dataURI
    b64_url = imagen_a_b64_dataurl(img)
    b64_path = ROOT / SPEC['logo']['archivo_b64']
    b64_path.write_text(b64_url, encoding='ascii')
    print(f'[OK]B64     ->{b64_path.name} ({len(b64_url)} chars)')

    # Preview 4x para inspección humana
    preview = img.resize((W * 4, H * 4), Image.NEAREST)
    preview_path = ROOT / 'logo-tonys-S-preview-4x.png'
    preview.save(preview_path, format='PNG')
    print(f'[OK]PREVIEW ->{preview_path.name} ({W*4}x{H*4})')


if __name__ == '__main__':
    main()
