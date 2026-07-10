"""Loop sutil de bienvenida TripSquad: vaivén de cámara + respiración de profundidad."""
import math
import sys
from pathlib import Path

from attrs import define
from depthflow.scene import DepthScene


@define
class BienvenidaLoop(DepthScene):
    def update(self) -> None:
        c = self.cycle  # 0 → 2π a lo largo del vídeo: cierra perfecto
        self.state.isometric = 0.45
        self.state.steady = 0.35          # pivote en las criaturas
        self.state.height = 0.24 + 0.05 * math.sin(c)          # la profundidad "respira"
        self.state.offset = (
            0.19 * math.sin(c),          # vaivén horizontal suave
            0.06 * math.sin(2 * c),      # cabeceo vertical más leve
        )
        self.state.zoom = 1.07 + 0.025 * math.sin(c + math.pi / 3)


def main() -> None:
    image, output = Path(sys.argv[1]), Path(sys.argv[2])
    scene = BienvenidaLoop(backend="headless")
    scene.ffmpeg.h264(preset="slow", crf=21)
    scene.input(image=image)
    scene.main(output=output, width=540, height=960, fps=30, time=6)


if __name__ == "__main__":
    main()
