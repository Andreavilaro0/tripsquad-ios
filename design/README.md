# design/ — assets de diseño de TripSquad

Carpeta pensada para que el archivo de Pencil viva AQUÍ: guarda `tripsquad.pen` en esta
carpeta (Pencil → Archivo → Guardar) para que las rutas relativas de imágenes y shaders
funcionen.

## Contenido

- `tripsquad-glow.glsl` — shader animado (WebGL 1.0) del gradiente de bienvenida:
  ondas lentas + glow que respira en el tercio inferior + grano. Se usa como fill
  `{type:"shader", url:"./tripsquad-glow.glsl"}` en Pencil. Colores y intensidad
  expuestos como uniforms con sliders.
- `bienvenida/` — las 5 escenas firmadas (ADR-0004):
  - `S*.png` — stills (Gemini 3 Pro, dirección A+C: translúcido-glow, sin bocas)
  - `S*-loop.mp4` — loops 2.5D de 6s (DepthFlow), cierre perfecto
  - `prompt-estilo.txt` — bloque de estilo FIJO para regenerar escenas
  - `df_loop.py` — animación DepthFlow (parámetros firmados)

## Cómo enchufar las escenas en Pencil (cuando el .pen esté guardado aquí)

Fill de imagen en el rect "Escena" de cada instancia:
`{type:"image", mode:"fill", url:"./bienvenida/S1-mesa.png"}`

## Regenerar una escena

```bash
python3 ~/.claude/skills/generate-image/scripts/generate_image.py \
  "<escena nueva> $(cat bienvenida/prompt-estilo.txt)" -o bienvenida/SX.png
python3 bienvenida/df_loop.py bienvenida/SX.png bienvenida/SX-loop.mp4
```
