/** @resolution */
uniform vec2 u_resolution;

/** @time */
uniform float u_time;

/**
 * @label Cielo (arriba)
 * @color
 * @default #241B45
 */
uniform vec3 u_top;

/**
 * @label Medio
 * @color
 * @default #5A3A5E
 */
uniform vec3 u_mid;

/**
 * @label Horizonte (abajo)
 * @color
 * @default #C96A4A
 */
uniform vec3 u_bottom;

/**
 * @label Glow
 * @color
 * @default #FFB266
 */
uniform vec3 u_glow;

/**
 * @label Intensidad glow
 * @range 0.0, 1.0
 * @default 0.45
 */
uniform float u_glowAmount;

/**
 * @label Ondas
 * @range 0.0, 1.0
 * @default 0.25
 */
uniform float u_waves;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution;

  // ondas lentas que desplazan el gradiente (estilo ColorBends)
  float w = sin(uv.x * 4.0 + u_time * 0.35) * 0.5
          + sin(uv.x * 9.0 - u_time * 0.22 + uv.y * 3.0) * 0.25;
  float y = clamp(uv.y + w * 0.05 * u_waves, 0.0, 1.0);

  // gradiente noche -> horizonte cálido (y=0 abajo)
  vec3 col = y < 0.5
    ? mix(u_bottom, u_mid, y * 2.0)
    : mix(u_mid, u_top, (y - 0.5) * 2.0);

  // glow que respira en el tercio inferior (donde viven las criaturas)
  float breath = 0.85 + 0.15 * sin(u_time * 1.05);
  float d = distance(uv * vec2(u_resolution.x / u_resolution.y, 1.0),
                     vec2(0.5 * u_resolution.x / u_resolution.y, 0.26));
  float glow = exp(-d * d * 9.0) * u_glowAmount * breath;
  col += u_glow * glow;

  // grano sutil
  col += (hash(gl_FragCoord.xy + fract(u_time)) - 0.5) * 0.035;

  gl_FragColor = vec4(col, 1.0);
}
