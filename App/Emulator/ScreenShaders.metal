// The game picture through Metal: a look (ORIGINAL, LISSÉ HD, LCD, CRT, REMASTER) and, over the field, the weather the
// game says (rain, storm, snow, fog, ash, sand, sun, under water) and the night's lights. ScreenRenderer.swift feeds it.
#include <metal_stdlib>
using namespace metal;

// a: texture w, h, view w, h (pixels). b: look, time (s), weather, effects strength (0..1).
// c: night (0..1), lightning flash (0..1), cave darkness (0..1), outdoors (0 / 1). d: the time of day's grade (r, g, b;
// 1 = none: by day, or when the game tints itself).
struct ScreenUniforms {
    float4 a;
    float4 b;
    float4 c;
    float4 d;
};

struct ScreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenOut screen_vertex(uint vid [[vertex_id]], constant ScreenUniforms& u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 tex = max(u.a.xy, float2(1));
    float2 view = max(u.a.zw, float2(1));
    float fit = min(view.x / tex.x, view.y / tex.y);
    float2 extent = tex * fit / view;
    float2 corner = corners[vid];
    ScreenOut o;
    o.position = float4(corner * extent, 0, 1);
    o.uv = float2((corner.x + 1) * 0.5, 1 - (corner.y + 1) * 0.5);
    return o;
}

// ---- helpers ----

static float3 texel(texture2d<float> t, int2 p) {
    int2 size = int2(t.get_width(), t.get_height());
    return t.read(uint2(clamp(p, int2(0), size - 1))).rgb;
}

static bool same(float3 x, float3 y) { return distance(x, y) < 0.09; }

static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3 - 2 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

static float fbm(float2 p) {
    float v = 0, w = 0.5;
    for (int i = 0; i < 4; i++) {
        v += w * noise2(p);
        p *= 2.03;
        w *= 0.5;
    }
    return v;
}

// EPX (Scale2x) on the fly: each pixel's quarter takes a neighbour's colour where two edges meet diagonally, so stairs
// become slopes. A second pass of the same rule on the quarters (sampled the same way) smooths them once more.
static float3 epx(texture2d<float> t, float2 tp) {
    int2 p = int2(floor(tp));
    float2 f = fract(tp);
    float3 P = texel(t, p);
    float3 A = texel(t, p + int2(0, -1)), B = texel(t, p + int2(1, 0));
    float3 C = texel(t, p + int2(-1, 0)), D = texel(t, p + int2(0, 1));
    bool right = f.x >= 0.5, down = f.y >= 0.5;
    if (!right && !down && same(C, A) && !same(C, D) && !same(A, B)) return A;
    if (right && !down && same(A, B) && !same(A, C) && !same(B, D)) return B;
    if (!right && down && same(D, C) && !same(D, B) && !same(C, A)) return C;
    if (right && down && same(B, D) && !same(B, A) && !same(D, C)) return D;
    return P;
}

// Smoother than EPX alone: four EPX samples a quarter pixel apart, averaged (edges come out anti-aliased).
static float3 smooth_hd(texture2d<float> t, float2 tp) {
    const float o = 0.22;
    return (epx(t, tp + float2(-o, -o)) + epx(t, tp + float2(o, -o)) + epx(t, tp + float2(-o, o)) + epx(t, tp + float2(o, o))) * 0.25;
}

// The bright parts around [uv], blurred: REMASTER's bloom and the night's lights.
static float3 glow(texture2d<float> t, sampler s, float2 uv, float2 texel_size, float threshold, bool warmOnly) {
    float3 sum = float3(0);
    float weight = 0;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.5235988;
        for (int r = 1; r <= 2; r++) {
            float2 off = float2(cos(a), sin(a)) * float(r) * 2.2 * texel_size;
            float3 c = t.sample(s, uv + off).rgb;
            float k = smoothstep(threshold, threshold + 0.18, luma(c));
            if (warmOnly) k *= smoothstep(0.02, 0.15, c.r - c.b);
            float w = 1.0 / float(r);
            sum += c * k * w;
            weight += w;
        }
    }
    return sum / weight;
}

// ---- weather layers (screen space; q = uv with the picture's aspect) ----

static float rain_layer(float2 q, float time, float density, float slant) {
    float acc = 0;
    for (int l = 0; l < 3; l++) {
        float scale = 22.0 + float(l) * 16.0;
        float speed = 1.9 + float(l) * 0.6;
        float2 g = q * float2(scale, scale * 0.22);
        g.y -= time * speed * scale * 0.22;
        g.x += g.y * slant;
        float2 id = floor(g), fr = fract(g);
        if (hash21(id + float(l) * 17.0) < density) {
            float x = 0.15 + 0.7 * hash21(id + 3.1);
            float streak = smoothstep(0.07, 0.0, abs(fr.x - x)) * smoothstep(0.0, 0.35, fr.y) * smoothstep(1.0, 0.65, fr.y);
            acc += streak * (0.35 + 0.22 * float(l));
        }
    }
    return acc;
}

static float flakes(float2 q, float time, float density, float fall, float size) {
    float acc = 0;
    for (int l = 0; l < 3; l++) {
        float scale = 7.0 + float(l) * 6.0;
        float2 g = q * scale;
        g.y -= time * (fall + float(l) * fall * 0.45) * scale;
        g.x += sin(time * 0.8 + float(l) * 1.7 + g.y * 0.45) * 0.35;
        float2 id = floor(g), fr = fract(g);
        if (hash21(id + float(l) * 7.0) < density) {
            float2 c = float2(0.25 + 0.5 * hash21(id + 1.3), 0.25 + 0.5 * hash21(id + 2.7));
            float r = size * (1.0 - float(l) * 0.22);
            acc += smoothstep(r, r * 0.25, length(fr - c)) * (0.55 + 0.2 * float(l));
        }
    }
    return acc;
}

static float3 weather_fx(float3 color, float2 uv, float2 q, float time, int weather, float strength, float flash) {
    if (strength <= 0.001) return color;
    float3 out = color;
    switch (weather) {
    case 3: case 5: case 13: { // rain, thunderstorm, downpour
        bool heavy = weather != 3;
        out *= mix(float3(1), float3(0.80, 0.84, 0.93), heavy ? 1.0 : 0.6);
        float r = rain_layer(q, time, heavy ? 0.34 : 0.2, 0.28);
        out += float3(0.75, 0.82, 0.95) * r * 0.38;
        // Splashes: brief rings low on the screen.
        float2 g = q * float2(14, 9);
        float2 id = floor(g);
        float phase = fract(time * 1.6 + hash21(id) * 7.0);
        float ring = smoothstep(0.05, 0.0, abs(length(fract(g) - 0.5) - phase * 0.35)) * (1 - phase);
        out += float3(0.8, 0.85, 1.0) * ring * 0.18 * step(0.6, hash21(id + 9.0)) * smoothstep(0.35, 0.9, uv.y);
        out += float3(0.9, 0.93, 1.0) * flash * 0.55;
        break;
    }
    case 4: { // snow
        out = mix(out, out * float3(0.92, 0.96, 1.05), 0.6);
        out += float3(1) * flakes(q, time, 0.42, 0.10, 0.14) * 0.85;
        break;
    }
    case 6: case 9: { // fog
        float n = fbm(q * 3.0 + float2(time * (weather == 9 ? 0.12 : 0.07), time * (weather == 9 ? 0.05 : 0.0)));
        out = mix(out, float3(0.88, 0.9, 0.93), smoothstep(0.35, 0.85, n) * 0.45);
        break;
    }
    case 7: { // volcanic ash
        out *= float3(0.92, 0.89, 0.86);
        out = mix(out, float3(0.45, 0.43, 0.42), flakes(q, time, 0.30, 0.05, 0.10) * 0.8);
        break;
    }
    case 8: { // sandstorm
        out = mix(out, float3(0.86, 0.68, 0.42), 0.22);
        float n = fbm(float2(q.x * 2.0 - time * 1.4, q.y * 9.0));
        out = mix(out, float3(0.93, 0.78, 0.52), smoothstep(0.45, 0.8, n) * 0.35);
        break;
    }
    case 12: { // drought (the game's harsh sun): warm light and rays from the top left; a plain sunny map stays as it is
        float2 d = uv - float2(-0.15, -0.25);
        float a = atan2(d.y, d.x);
        float rays = pow(0.5 + 0.5 * sin(a * 14.0 + time * 0.25 + noise2(float2(a * 6.0, time * 0.2)) * 2.0), 6.0);
        float fall = smoothstep(1.4, 0.1, length(d));
        float k = 1.0;
        out *= mix(float3(1), float3(1.06, 1.02, 0.94), k);
        out += float3(1.0, 0.92, 0.7) * rays * fall * 0.16 * k;
        break;
    }
    case 10: case 14: { // under water: blue, and moving light from the surface
        out = mix(out, out * float3(0.75, 0.9, 1.1), 0.6);
        float c = pow(abs(sin(q.x * 9.0 + time * 1.3 + sin(q.y * 7.0 + time)) * sin(q.y * 8.0 - time * 1.1)), 3.0);
        out += float3(0.5, 0.75, 0.9) * c * 0.12;
        break;
    }
    case 11: // shade
        out *= 0.86;
        break;
    case 0: case 1: case 2: { // a fine day: cloud shadows drifting over the map, a touch of warm light
        float n = fbm(q * 1.1 + float2(time * 0.035, time * 0.012));
        float shadow = smoothstep(0.46, 0.74, n) * (weather == 1 ? 0.28 : 0.22);
        out *= (1.0 - shadow) * float3(1.03, 1.01, 0.97);
        break;
    }
    default:
        return color;
    }
    return mix(color, out, strength);
}

// ---- the picture ----

fragment float4 screen_fragment(ScreenOut in [[stage_in]], texture2d<float> frame [[texture(0)]],
                                constant ScreenUniforms& u [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float2 tex = max(u.a.xy, float2(1));
    float2 uv = in.uv;
    float2 tp = uv * tex;
    float2 texel_size = 1.0 / tex;
    int look = int(u.b.x + 0.5);
    float time = u.b.y;
    int weather = int(u.b.z + 0.5);
    float strength = u.b.w;
    float night = u.c.x, flash = u.c.y, cave = u.c.z, outdoors = u.c.w;

    float3 color;
    if (look == 1 || look == 4) {
        color = smooth_hd(frame, tp);
    } else {
        color = frame.sample(nearest, uv).rgb;
    }
    float2 f = fract(tp);
    if (look == 2) { // LCD: the grid between pixels, a hint of its sub-pixels
        float gx = smoothstep(0.0, 0.14, f.x) * smoothstep(0.0, 0.14, 1 - f.x);
        float gy = smoothstep(0.0, 0.14, f.y) * smoothstep(0.0, 0.14, 1 - f.y);
        color *= mix(0.72, 1.0, gx * gy);
        float3 sub = f.x < 0.333 ? float3(1.06, 0.97, 0.97) : f.x < 0.666 ? float3(0.97, 1.06, 0.97) : float3(0.97, 0.97, 1.06);
        color *= sub;
    } else if (look == 3) { // CRT: scanlines, a soft bloom, darker corners
        float scan = 0.72 + 0.28 * sin(f.y * 3.14159);
        color = color * scan + glow(frame, linear, uv, texel_size, 0.55, false) * 0.35;
        float2 v = uv * (1 - uv);
        color *= pow(saturate(v.x * v.y * 18.0), 0.18);
    } else if (look == 4) { // REMASTER: richer colours, contrast, bloom, a light vignette
        float l = luma(color);
        color = mix(float3(l), color, 1.18);
        color = (color - 0.5) * 1.07 + 0.5;
        color += glow(frame, linear, uv, texel_size, 0.62, false) * 0.28;
        float2 v = uv * (1 - uv);
        color *= mix(0.86, 1.0, saturate(pow(v.x * v.y * 16.0, 0.3)));
    }

    // The time of day (the phone's clock): night blue, dawn pink, dusk orange, a little less colour at night.
    float3 grade = u.d.xyz;
    if (any(grade < float3(0.999))) {
        float dark = 1.0 - (grade.x + grade.y) * 0.5;
        float l = luma(color);
        color = mix(color, float3(l), dark * 0.5) * grade;
    }
    if (strength > 0.001) {
        float2 q = float2(uv.x * tex.x / tex.y, uv.y);
        color = weather_fx(color, uv, q, time, weather, strength * outdoors, flash);
        // The night: darker edges, a warm light round the player (the picture's middle), warm bright spots glowing and,
        // on a clear night outdoors, fireflies.
        if (night > 0.01) {
            float d = length((uv - 0.5) * float2(tex.x / tex.y, 1));
            float k = night * strength;
            // Darker away from the player, a warm pool of light round them (lit as by a lantern).
            color *= mix(1.0, 0.5, smoothstep(0.2, 0.85, d) * k);
            float pool = smoothstep(0.42, 0.0, d);
            color = color * (1.0 + pool * k * 0.55) + float3(0.24, 0.15, 0.05) * pool * k * 0.5;
            float3 g = glow(frame, linear, uv, texel_size, 0.3, true);
            color += g * float3(1.0, 0.82, 0.5) * k * 1.6;
            if (outdoors > 0.5 && weather <= 2) {
                float2 fq = q * 5.0 + float2(sin(time * 0.3) * 0.4, time * -0.05);
                float2 id = floor(fq), fr = fract(fq);
                float2 c = float2(0.2 + 0.6 * hash21(id + 4.1), 0.2 + 0.6 * hash21(id + 8.3));
                c += float2(sin(time * 1.3 + hash21(id) * 6.28), cos(time * 1.1 + hash21(id + 1.0) * 6.28)) * 0.12;
                float blink = 0.5 + 0.5 * sin(time * 2.4 + hash21(id + 2.0) * 6.28);
                float dist = length(fr - c);
                float fly = (smoothstep(0.05, 0.0, dist) + smoothstep(0.16, 0.0, dist) * 0.35) * blink * step(0.7, hash21(id + 5.5));
                color += float3(0.8, 1.0, 0.45) * fly * k * 1.2;
            }
        }
        if (cave > 0.01) {
            float d = length((uv - 0.5) * float2(tex.x / tex.y, 1));
            color += float3(0.35, 0.22, 0.08) * smoothstep(0.32, 0.0, d) * cave * 0.35 * strength;
        }
    }
    return float4(saturate(color), 1);
}
