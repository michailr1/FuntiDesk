"""Экспорт иконок Android-клиента из канонического знака FuntiDesk (docs/ANDROID.md).

Растеризация SVG — Skia (pip install skia-python numpy): headless Edge 154
перестал сохранять скриншоты, а Skia рисует SVG одинаково на любой машине.

  ic_launcher / ic_launcher_round — знак целиком на прозрачном фоне;
  ic_launcher_foreground — передний план адаптивной иконки: знак в безопасной
    зоне (66 из 108 dp), фон — цвет ic_launcher_background;
  ic_launcher_monochrome — белый силуэт для тематических иконок Android 13;
  ic_stat_logo — белый силуэт для строки уведомлений.

Запуск из корня репозитория: python scripts/brand/export_android_icons.py
"""

import pathlib

import numpy as np
import skia

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "design" / "brand" / "funtidesk-mark.svg"
RES = ROOT / "client" / "flutter" / "android" / "app" / "src" / "main" / "res"
DENSITIES = {"mipmap-mdpi": 1.0, "mipmap-hdpi": 1.5, "mipmap-xhdpi": 2.0,
             "mipmap-xxhdpi": 3.0, "mipmap-xxxhdpi": 4.0}


def render(canvas_px: int, mark_px: int) -> np.ndarray:
    """RGBA (unpremultiplied) canvas with the mark centred."""
    dom = skia.SVGDOM.MakeFromStream(skia.Stream.MakeFromFile(str(SOURCE)))
    info = skia.ImageInfo.Make(canvas_px, canvas_px, skia.kRGBA_8888_ColorType,
                               skia.kUnpremul_AlphaType)
    surface = skia.Surface.MakeRaster(info)
    canvas = surface.getCanvas()
    canvas.clear(skia.ColorTRANSPARENT)
    offset = (canvas_px - mark_px) / 2
    canvas.translate(offset, offset)
    canvas.scale(mark_px / 256.0, mark_px / 256.0)  # viewBox 0 0 256 256
    dom.setContainerSize(skia.Size(256, 256))
    dom.render(canvas)
    return np.array(surface.makeImageSnapshot().toarray(colorType=skia.kRGBA_8888_ColorType,
                                                       alphaType=skia.kUnpremul_AlphaType))


def silhouette(rgba: np.ndarray) -> np.ndarray:
    """White silhouette: the blue body stays, the white window inside goes."""
    r = rgba[..., 0].astype(np.int32)
    b = rgba[..., 2].astype(np.int32)
    blue = np.clip((b - r) * 2, 0, 255)
    out = np.zeros_like(rgba)
    out[..., :3] = 255
    out[..., 3] = (rgba[..., 3].astype(np.int32) * blue // 255).astype(np.uint8)
    return out


def save(rgba: np.ndarray, folder: str, name: str) -> None:
    path = RES / folder / name
    image = skia.Image.fromarray(np.ascontiguousarray(rgba), colorType=skia.kRGBA_8888_ColorType,
                                 alphaType=skia.kUnpremul_AlphaType)
    image.save(str(path), skia.kPNG)
    print(f"{folder}/{name} <- {rgba.shape[0]}")


def main() -> None:
    for folder, k in DENSITIES.items():
        launcher = round(48 * k)
        icon = render(launcher, launcher)
        save(icon, folder, "ic_launcher.png")
        save(icon, folder, "ic_launcher_round.png")

        # Adaptive icon: 108 dp canvas, mark inside the 66 dp safe zone (64 dp).
        foreground = render(round(108 * k), round(64 * k))
        save(foreground, folder, "ic_launcher_foreground.png")
        save(silhouette(foreground), folder, "ic_launcher_monochrome.png")

        # Status bar: 24 dp, mark 22 dp.
        save(silhouette(render(round(24 * k), round(22 * k))), folder, "ic_stat_logo.png")


if __name__ == "__main__":
    main()
