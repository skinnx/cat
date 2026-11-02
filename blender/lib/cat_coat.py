"""Authentic Vietnamese Orange Tabby ('Mèo Cam / Mèo Vàng Ta') coat pattern and fur fields.

Evaluated in 3D rest-pose object space `(x, y, z)` (with the cat facing `-Y`, `+Z` up) and
head design space `ph = S.world_to_head(p)` (`hx, hy, hz`, where `EYE_L = (0.0168, -0.205, 0.2496)`
and `NOSE_TIP = (0, -0.225, 0.2345)`), so every stripe, facial marking, paw mitten, and chest
bib is 100% seamless across UV islands and anatomically aligned to the 3D head landmarks.
"""
from __future__ import annotations

import math
import numpy as np

import cat_anatomy as A
import cat_parts as P
import cat_sdf as S
from cat_tex import fbm3 as _tex_fbm3, hexc, lerp, perlin3, smoothstep, srgb_to_lin


def fbm3(x, y, z, octaves=2, seed=0):
    return _tex_fbm3(np.stack([x, y, z], axis=-1), octaves=octaves, seed=seed)


def vnoise3(x, y, z, seed=0):
    return perlin3(np.stack([x, y, z], axis=-1), seed=seed)


def fields(p: np.ndarray, n: np.ndarray, part_id: np.ndarray) -> dict[str, np.ndarray]:
    """`p` (N,3) rest-pose position, `n` (N,3) unit normal, `part_id` (N,3) vertex colour
    (R=ear, G=teeth, B=tongue)."""
    x, y, z = p[:, 0], p[:, 1], p[:, 2]
    ax = np.abs(x)
    nx, ny, nz = n[:, 0], n[:, 1], n[:, 2]

    is_ear = np.clip(part_id[:, 0], 0, 1)
    is_teeth = np.clip(part_id[:, 1], 0, 1)
    is_tongue = np.clip(part_id[:, 2], 0, 1)
    is_skin = np.clip(1.0 - np.maximum(np.maximum(is_ear, is_teeth), is_tongue), 0, 1)

    # Evaluate head inverse-warp & SDF only on head/neck texels (y < -0.105)
    hm = y < -0.105
    ph = p.copy()
    if np.any(hm):
        ph[hm] = S.world_to_head(p[hm])
    hx, hy, hz = ph[:, 0], ph[:, 1], ph[:, 2]
    ahx = np.abs(hx)

    # Organic 3D coordinate warp so markings have natural hand-painted hair-lock variation
    w1 = fbm3(x * 24, y * 24, z * 24, 2, 101) * 0.0050
    w2 = fbm3(x * 24 + 5, y * 24, z * 24, 2, 107) * 0.0050
    xw, yw, zw = x + w1, y + w2, z + w1 * 0.6
    axw = np.abs(xw)
    micro_edge = fbm3(x * 85, y * 85, z * 85, 2, 199) * 0.08

    # ------------------------------------------------------------------
    # 1. Special bare / anatomical zones (in head design space `ph`)
    # ------------------------------------------------------------------
    # Feline rhinarium (nose leather): triangular pad on the nose tip (NOSE_TIP = (0, -0.225, 0.2345))
    nose_top = 0.2388 - 0.20 * np.maximum(0.0, ahx - 0.0012)
    nose_bot = 0.2314 + 0.52 * ahx
    in_nose_z = smoothstep(nose_bot - 0.0010, nose_bot + 0.0008, hz) * (1.0 - smoothstep(nose_top - 0.0008, nose_top + 0.0010, hz))
    in_nose_x = 1.0 - smoothstep(0.0050, 0.0064, ahx)
    in_nose_y = smoothstep(-0.2130, -0.2168, hy)
    nose = np.clip(in_nose_z * in_nose_x * in_nose_y, 0.0, 1.0) * is_skin

    # Nostrils (comma-shaped dark slits on the lower lateral wings of the rhinarium)
    nd = ((ahx - 0.0025) / 0.0013) ** 2 + ((hy - (-0.2185)) / 0.0022) ** 2 + ((hz - 0.2342) / 0.0013) ** 2
    nostril = (1.0 - smoothstep(0.45, 1.15, nd)) * nose
    nose_rim = smoothstep(0.12, 0.48, nose) * (1.0 - smoothstep(0.48, 0.88, nose))

    # Paw pads (under all 4 paws, facing down nz < -0.15)
    fore_d = np.sqrt((ax - 0.031) ** 2 + (y - (-0.100)) ** 2)
    hind_d = np.sqrt((ax - 0.031) ** 2 + (y - 0.148) ** 2)
    pad_zone = (1 - smoothstep(0.015, 0.021, np.minimum(fore_d, hind_d))) * (1 - smoothstep(0.004, 0.012, z)) * smoothstep(-0.15, -0.55, nz)
    dig_fore = 1 - smoothstep(0.0038, 0.0052, np.sqrt(((ax - 0.031) * 1.1) ** 2 + (y - (-0.110)) ** 2))
    meta_fore = 1 - smoothstep(0.0055, 0.0075, np.sqrt((ax - 0.031) ** 2 + (y - (-0.095)) ** 2))
    dig_hind = 1 - smoothstep(0.0038, 0.0052, np.sqrt(((ax - 0.031) * 1.1) ** 2 + (y - 0.138) ** 2))
    meta_hind = 1 - smoothstep(0.0055, 0.0075, np.sqrt((ax - 0.031) ** 2 + (y - 0.152) ** 2))
    paw_pad = np.clip(np.maximum(np.maximum(dig_fore, meta_fore), np.maximum(dig_hind, meta_hind)) * pad_zone, 0, 1) * is_skin

    # Inner ear pinna: soft gradual fade from ear base to inner pinna cup (no sharp horizontal cutoff)
    ear_base_z = A.head_to_world(A.EAR_BASE_L)[2]
    ear_h = np.clip((z - ear_base_z) / A.EAR_HEIGHT, 0, 1)
    inner_ear = is_ear * smoothstep(-0.02, -0.42, ny) * smoothstep(0.0, 0.32, ear_h) * (1 - smoothstep(0.82, 0.96, ear_h))

    # Eyelid margins & delicate warm spectacles around the eyes (in head design space `ph`)
    ec = np.array([abs(A.EYE_L[0]), A.EYE_L[1], A.EYE_L[2]])
    eye_d = np.sqrt((ahx - ec[0]) ** 2 + (hy - ec[1]) ** 2 + (hz - ec[2]) ** 2)
    near_eye = (1.0 - smoothstep(A.EYE_RADIUS + 0.0010, A.EYE_RADIUS + 0.0042, eye_d)) * is_skin
    lid_rim = (1.0 - smoothstep(A.EYE_RADIUS - 0.0005, A.EYE_RADIUS + 0.0016, eye_d)) * is_skin
    # Subtle, narrow warm-cream highlight right outside the dark lid liner (no wide white goggles!)
    eye_ring = (
        smoothstep(A.EYE_RADIUS + 0.0006, A.EYE_RADIUS + 0.0018, eye_d)
        * (1.0 - smoothstep(A.EYE_RADIUS + 0.0022, A.EYE_RADIUS + 0.0045, eye_d))
        * is_skin
    )

    # Delicate feline philtrum & inverted-Y ('ㅅ') lip line under the nose (in `ph`)
    philtrum = (
        (1.0 - smoothstep(0.0003, 0.0011, ahx))
        * smoothstep(0.221, 0.224, hz)
        * (1.0 - smoothstep(0.231, 0.233, hz))
        * smoothstep(-0.212, -0.217, hy)
        * is_skin
    )
    lip_arch_z = 0.2218 - 0.48 * ahx
    lip_line = (
        np.exp(-((hz - lip_arch_z) / 0.0008) ** 2)
        * (1.0 - smoothstep(0.0045, 0.0080, ahx))
        * smoothstep(-0.208, -0.215, hy)
        * is_skin
    )

    # Oral cavity interior: strictly deep inside the carved mouth
    hsdf = np.ones(len(p), dtype=np.float64)
    if np.any(hm):
        hsdf[hm] = S.head_sdf(ph[hm])
    in_cavity = -hsdf
    mouth_interior = (
        smoothstep(0.0045, 0.0078, in_cavity)
        * (1.0 - smoothstep(0.0060, 0.0085, ahx))
        * (1.0 - smoothstep(-0.196, -0.186, hy))
        * smoothstep(0.212, 0.216, hz)
        * (1.0 - smoothstep(0.226, 0.230, hz))
        * is_skin
    )

    # ------------------------------------------------------------------
    # 2. Tabby stripe field (0..1) — Vietnamese Mackerel Tabby ('Mèo Vàng Ta')
    # ------------------------------------------------------------------
    # Dorsal spine stripe (3 parallel dark lines merged along the back)
    dorsal_env = smoothstep(-0.08, 0.19, yw) * (1 - smoothstep(0.19, 0.23, yw)) * smoothstep(0.17, 0.21, zw)
    dorsal_3 = np.exp(-((axw - 0.0) / 0.0065) ** 2) + 0.78 * np.exp(-((axw - 0.0135) / 0.0055) ** 2)
    dorsal = np.clip(dorsal_3, 0, 1) * dorsal_env

    # Curved mackerel rib stripes ('vằn xương cá')
    flank = smoothstep(-0.08, -0.02, yw) * (1 - smoothstep(0.16, 0.20, yw)) * smoothstep(0.11, 0.145, zw) * (1 - smoothstep(0.215, 0.238, zw))
    z_norm = np.clip((0.215 - zw) / 0.095, 0, 1)
    rib_curve = yw - 0.028 * np.sin(z_norm * math.pi * 0.85) + 0.012 * (z_norm ** 2)
    rib_phase = np.cos(rib_curve * 2 * math.pi / 0.024)
    ribs = smoothstep(0.10, 0.58, rib_phase + micro_edge) * flank * smoothstep(0.010, 0.022, axw)

    # Shoulder & hip classic whorls
    sh_d = np.sqrt((yw - (-0.068)) ** 2 + ((zw - 0.168) * 1.15) ** 2)
    sh_ring = smoothstep(0.25, 0.68, np.cos(sh_d * 2 * math.pi / 0.024) + micro_edge) * (1 - smoothstep(0.036, 0.056, sh_d)) * smoothstep(0.018, 0.030, axw)
    th_d = np.sqrt((yw - 0.148) ** 2 + ((zw - 0.160) * 1.1) ** 2)
    th_ring = smoothstep(0.25, 0.68, np.cos(th_d * 2 * math.pi / 0.025) + micro_edge) * (1 - smoothstep(0.038, 0.058, th_d)) * smoothstep(0.018, 0.030, axw)

    # Necklace bands ('vòng cổ') framing the upper chest/shoulders
    neck_d1 = np.abs((yw - (-0.118)) + 0.35 * (zw - 0.182))
    neck_d2 = np.abs((yw - (-0.096)) + 0.32 * (zw - 0.165))
    necklace = (np.exp(-(neck_d1 / 0.0055) ** 2) + 0.85 * np.exp(-(neck_d2 / 0.0060) ** 2))
    necklace *= smoothstep(0.145, 0.165, zw) * (1 - smoothstep(0.215, 0.230, zw)) * smoothstep(0.010, 0.020, axw) * (1 - smoothstep(-0.065, -0.045, yw))

    # Forehead 'M' mark right above/between the eyes (in head design space `ph`)
    u_m = ahx / 0.0165
    hz_m = 0.2515 + 0.0088 * np.sin(np.clip(u_m, 0.0, 1.0) * math.pi * 1.15) - 0.0032 * (u_m ** 2)
    m_arch = np.exp(-((hz - hz_m) / 0.0028) ** 2) * (1.0 - smoothstep(0.0165, 0.0205, ahx))
    brow_v1 = np.exp(-((ahx - 0.0036) / 0.0019) ** 2) * smoothstep(0.245, 0.250, hz) * (1.0 - smoothstep(0.262, 0.268, hz))
    brow_v2 = np.exp(-((ahx - 0.0098) / 0.0020) ** 2) * smoothstep(0.249, 0.254, hz) * (1.0 - smoothstep(0.264, 0.270, hz))
    m_env = smoothstep(-0.175, -0.192, hy) * smoothstep(0.243, 0.248, hz) * (1.0 - smoothstep(0.266, 0.272, hz))
    m_mark = np.clip(m_arch * 0.92 + (brow_v1 + brow_v2) * 0.85, 0.0, 1.0) * m_env

    # 5 longitudinal crown stripes sweeping over the skull from the forehead M to the nape (in `ph`)
    crown_env = smoothstep(-0.135, -0.155, hy) * (1.0 - smoothstep(-0.198, -0.188, hy)) * smoothstep(0.250, 0.258, hz) * (1.0 - smoothstep(0.020, 0.026, ahx))
    crown_5 = np.cos(ahx / 0.022 * 2.0 * math.pi * 2.5)
    crown = smoothstep(0.15, 0.65, crown_5 + micro_edge) * crown_env

    # Expressive cheek 'mascara' (Cleopatra) stripes sweeping back from the outer eye corner (in `ph`)
    cheek_env = smoothstep(-0.155, -0.172, hy) * (1.0 - smoothstep(-0.208, -0.196, hy)) * smoothstep(0.222, 0.230, hz) * (1.0 - smoothstep(0.252, 0.258, hz)) * smoothstep(0.013, 0.019, ahx)
    c_line1 = np.exp(-(((hz - 0.245) - 0.26 * (hy - (-0.198))) / 0.0020) ** 2)
    c_line2 = np.exp(-(((hz - 0.234) - 0.28 * (hy - (-0.196))) / 0.0022) ** 2)
    cheek = np.clip(c_line1 + 0.85 * c_line2, 0.0, 1.0) * cheek_env

    # Horizontal leg bracelets (stopped above the white mittens at z < 0.045)
    in_leg = (1 - smoothstep(0.135, 0.165, zw)) * smoothstep(0.038, 0.052, zw) * ((yw < -0.03) | (yw > 0.09))
    leg_bars = smoothstep(0.20, 0.66, np.cos(zw * 2 * math.pi / 0.022) + micro_edge) * in_leg

    # 8 rhythmic tail rings + solid dark tail tip
    in_tail = smoothstep(0.195, 0.228, y)
    t_arc = np.clip((yw - 0.215) / 0.265, 0, 1)
    tail_rings = smoothstep(0.08, 0.55, np.cos(t_arc * 2 * math.pi * 8.5)) * in_tail
    tail_tip = smoothstep(0.84, 0.94, t_arc) * in_tail

    stripe = np.maximum.reduce([
        dorsal,
        ribs * 0.92,
        sh_ring * 0.88,
        th_ring * 0.88,
        necklace * 0.85,
        m_mark * 0.95,
        crown * 0.90,
        cheek * 0.90,
        leg_bars * 0.85,
        tail_rings * 0.95,
        tail_tip,
    ])
    stripe *= is_skin * (1 - nose) * (1 - paw_pad) * (1 - lid_rim)

    # ------------------------------------------------------------------
    # 3. White markings ('mèo vàng ức trắng bốn tất trắng') & countershading
    # ------------------------------------------------------------------
    # Compact, rounded white omega whisker pads strictly under the pink nose (ahx < 0.0115)
    # so the cheeks stay warm golden-apricot!
    pad_d = (
        ((ahx - 0.0046) / 0.0068) ** 2
        + ((hy - (-0.2145)) / 0.0115) ** 2
        + ((hz - 0.2245) / 0.0078) ** 2
    )
    white_pads = (1.0 - smoothstep(0.45, 1.15, pad_d)) * (1.0 - smoothstep(0.2315, 0.2365, hz))
    white_philtrum = (
        smoothstep(-0.206, -0.220, hy)
        * (1.0 - smoothstep(0.2320, 0.2365, hz))
        * smoothstep(0.215, 0.221, hz)
        * (1.0 - smoothstep(0.0045, 0.0085, ahx))
    )
    white_chin = (
        smoothstep(-0.172, -0.195, hy)
        * (1.0 - smoothstep(0.2175, 0.2235, hz))
        * (1.0 - smoothstep(0.0095, 0.0165, ahx))
    )
    white_muzzle = np.maximum(np.maximum(white_pads, white_philtrum), white_chin)

    # Symmetric white throat & chest bib ('ức trắng')
    bib_w = 0.020 + 0.016 * smoothstep(-0.165, -0.085, yw) * (1.0 - smoothstep(-0.075, -0.020, yw))
    white_bib = (
        smoothstep(-0.180, -0.150, yw)
        * (1.0 - smoothstep(-0.045, 0.005, yw))
        * (1.0 - smoothstep(0.192, 0.218, zw))
        * smoothstep(0.115, 0.145, zw)
        * (1.0 - smoothstep(bib_w * 0.72, bib_w, axw))
        * smoothstep(-0.35, 0.15, -ny - 0.35 * nz)
    )

    # White belly & inguinal underside
    white_belly = (
        smoothstep(-0.08, -0.03, yw)
        * (1.0 - smoothstep(0.16, 0.20, yw))
        * (1.0 - smoothstep(0.150, 0.175, zw))
        * (1.0 - smoothstep(0.024, 0.038, axw))
        * smoothstep(0.10, -0.42, nz)
    )

    # Four neat white paw socks / mittens ('bốn tất trắng')
    sock_h = 0.034 + 0.004 * np.sin(np.arctan2(xw, yw) * 3.0) + w1 * 0.35
    white_paws = (1.0 - smoothstep(sock_h - 0.006, sock_h + 0.006, zw)) * ((yw < -0.04) | (yw > 0.08))

    white_zone = np.clip(
        np.maximum.reduce([white_muzzle, white_bib, white_belly, white_paws]),
        0.0,
        1.0,
    ) * is_skin * (1.0 - nose) * (1.0 - paw_pad) * (1.0 - lid_rim)

    # Soft warm cream countershading on lower flanks
    cream_flank = (
        smoothstep(-0.14, -0.06, yw)
        * (1.0 - smoothstep(0.16, 0.20, yw))
        * (1.0 - smoothstep(0.165, 0.198, zw))
        * (1.0 - smoothstep(0.032, 0.046, axw))
    )
    belly = np.clip(np.maximum(white_zone, np.maximum(cream_flank * 0.60, eye_ring * 0.18)), 0.0, 1.0)
    belly *= is_skin * (1.0 - nose) * (1.0 - paw_pad) * (1.0 - lid_rim)

    # Fade stripes smoothly across the white bib, paws, and muzzle
    stripe *= (1.0 - 0.95 * white_zone) * (1.0 - 0.60 * cream_flank)

    # ------------------------------------------------------------------
    # 4. Fur length & density (0..1; 1 == A.FUR_MAX_LENGTH = 16 mm)
    # ------------------------------------------------------------------
    bare = np.clip(
        nose
        + paw_pad
        + is_teeth
        + is_tongue
        + inner_ear * 0.85
        + lid_rim
        + philtrum * 0.85
        + lip_line * 0.85
        + mouth_interior,
        0,
        1,
    )
    eye_clear = 1.0 - smoothstep(A.EYE_RADIUS - 0.0005, A.EYE_RADIUS + 0.0055, eye_d)
    lip_clear = (
        smoothstep(-0.202, -0.214, hy)
        * smoothstep(0.213, 0.218, hz)
        * (1.0 - smoothstep(0.228, 0.233, hz))
        * (1.0 - smoothstep(0.009, 0.014, ahx))
    )

    len_head = smoothstep(-0.155, -0.210, y) * smoothstep(0.21, 0.24, z)
    len_face = smoothstep(-0.180, -0.215, y) * smoothstep(0.21, 0.24, z)
    len_paw = (1.0 - smoothstep(0.015, 0.070, z)) * ((y < -0.04) | (y > 0.09))
    len_ruff = (
        smoothstep(-0.165, -0.125, y)
        * (1.0 - smoothstep(-0.075, -0.040, y))
        * smoothstep(0.16, 0.20, z)
        * (1.0 - smoothstep(0.25, 0.28, z))
    )
    len_tail = in_tail * (1.0 - 0.22 * t_arc)

    fur_len = np.full(len(p), 0.72, dtype=np.float64)
    fur_len = lerp(fur_len, 0.90, len_ruff)
    fur_len = lerp(fur_len, 0.82, len_tail)
    fur_len = lerp(fur_len, 0.28, len_head)
    fur_len = lerp(fur_len, 0.12, len_face)
    fur_len = lerp(fur_len, 0.24, len_paw)
    fur_len *= (1.0 - is_ear) * (1.0 - eye_clear) * (1.0 - 0.75 * lip_clear) * (1.0 - bare)
    midline_chest = (
        (1.0 - smoothstep(0.000, 0.0045, ax))
        * smoothstep(-0.18, -0.14, y)
        * (1.0 - smoothstep(0.14, 0.18, y))
        * (1.0 - smoothstep(0.21, 0.24, z))
    )
    fur_len *= 1.0 - 0.30 * midline_chest
    fur_len = np.clip(fur_len + 0.03 * fbm3(x * 35, y * 35, z * 35, 2, 303) * (1.0 - bare) * (1.0 - is_ear), 0.0, 1.0)

    fur_den = np.where(bare > 0.5, 0.0, 0.88 - 0.65 * inner_ear - 0.25 * is_ear + 0.05 * fbm3(x * 40, y * 40, z * 40, 2, 311))
    fur_den = np.clip(fur_den * (1.0 - bare) * (1.0 - 0.85 * eye_clear), 0.0, 1.0)

    # ------------------------------------------------------------------
    # 5. 3D Tangent-projected Fur Flow Direction
    # ------------------------------------------------------------------
    flow = np.zeros_like(p)
    flow[:, 0] = 0.20 * np.sign(x) * smoothstep(0.005, 0.025, ax)
    flow[:, 1] = 0.92
    flow[:, 2] = -0.32
    head_w = smoothstep(-0.14, -0.18, y) * smoothstep(0.20, 0.24, z)
    nose_p = np.array(A.head_to_world(A.NOSE_TIP))
    from_nose = p - nose_p
    fn_l = np.linalg.norm(from_nose, axis=1, keepdims=True) + 1e-8
    flow = lerp(flow, from_nose / fn_l, head_w)
    leg_w = (1.0 - smoothstep(0.13, 0.17, z)) * ((y < -0.02) | (y > 0.08))
    flow = lerp(flow, np.broadcast_to([0.0, 0.18, -0.98], flow.shape), leg_w)
    tp = np.asarray(A.tail_points())
    t_dir = tp[-1] - tp[0]
    t_dir = t_dir / np.linalg.norm(t_dir)
    flow = lerp(flow, np.broadcast_to(t_dir, flow.shape), in_tail)
    flow = lerp(flow, np.broadcast_to([0.0, 0.0, 1.0], flow.shape), is_ear)
    dot_fn = np.einsum("ij,ij->i", flow, n)
    flow = flow - dot_fn[:, None] * n
    fl = np.linalg.norm(flow, axis=1, keepdims=True)
    flow = np.where(fl > 1e-5, flow / np.maximum(fl, 1e-5), np.broadcast_to([0.0, 1.0, 0.0], flow.shape))

    return {
        "stripe": stripe.astype(np.float32),
        "belly": belly.astype(np.float32),
        "white_zone": white_zone.astype(np.float32),
        "fur_len": fur_len.astype(np.float32),
        "fur_den": fur_den.astype(np.float32),
        "flow": flow.astype(np.float32),
        "nose": nose.astype(np.float32),
        "nostril": nostril.astype(np.float32),
        "nose_rim": nose_rim.astype(np.float32),
        "paw_pad": paw_pad.astype(np.float32),
        "inner_ear": inner_ear.astype(np.float32),
        "is_ear": is_ear.astype(np.float32),
        "is_teeth": is_teeth.astype(np.float32),
        "is_tongue": is_tongue.astype(np.float32),
        "near_eye": near_eye.astype(np.float32),
        "lid_rim": lid_rim.astype(np.float32),
        "eye_ring": eye_ring.astype(np.float32),
        "philtrum": philtrum.astype(np.float32),
        "lip_line": lip_line.astype(np.float32),
        "mouth_interior": mouth_interior.astype(np.float32),
        "bare": bare.astype(np.float32),
        "agouti": fbm3(x * 130, y * 130, z * 130, 2, 601).astype(np.float32),
        "coat_var": fbm3(x * 18, y * 18, z * 18, 2, 613).astype(np.float32),
        "vein": fbm3(x * 70, y * 70, z * 70, 2, 631).astype(np.float32),
    }


def strand_height(p: np.ndarray, flow: np.ndarray, fur_len: np.ndarray) -> np.ndarray:
    """Anisotropic high-frequency height field (0..1) elongated along `flow`."""
    x, y, z = p[:, 0], p[:, 1], p[:, 2]
    s_along = (x * flow[:, 0] + y * flow[:, 1] + z * flow[:, 2]) * 95.0
    q1 = np.stack([x * 420 - s_along * flow[:, 0] * 3.3,
                   y * 420 - s_along * flow[:, 1] * 3.3,
                   z * 420 - s_along * flow[:, 2] * 3.3], -1)
    q2 = q1 * 2.15 + 17.3
    h = 0.65 * vnoise3(q1[:, 0], q1[:, 1], q1[:, 2], 501) + 0.35 * vnoise3(q2[:, 0], q2[:, 1], q2[:, 2], 509)
    clump = fbm3(x * 55, y * 55, z * 55, 2, 521)
    return ((h * 0.7 + clump * 0.3) * np.sqrt(np.clip(fur_len, 0, 1))).astype(np.float32)


# ---------------------------------------------------------------------------
# Coat colour palettes (sRGB hex -> converted to linear for blending)
# ---------------------------------------------------------------------------
PALETTES = {
    "cam": dict(
        base=hexc("f09b38"),
        base_hi=hexc("f8b458"),
        dorsal=hexc("d9711e"),
        stripe=hexc("a83c0e"),
        stripe_dark=hexc("7a2607"),
        belly=hexc("fae8cc"),
        white=hexc("fcf5e8"),
        nose=hexc("ee8f88"),
        pad=hexc("df8884"),
        inner_ear=hexc("f2b2ac"),
        eye_rim=hexc("4a220c"),
    ),
    "black": dict(
        base=hexc("1c1a18"),
        base_hi=hexc("252220"),
        dorsal=hexc("151311"),
        stripe=hexc("100e0d"),
        stripe_dark=hexc("0a0908"),
        belly=hexc("262320"),
        white=hexc("f2ede4"),
        nose=hexc("2a2322"),
        pad=hexc("332827"),
        inner_ear=hexc("7a5550"),
        eye_rim=hexc("0e0c0b"),
    ),
    "white": dict(
        base=hexc("f2ede3"),
        base_hi=hexc("faf6ee"),
        dorsal=hexc("eae2d4"),
        stripe=hexc("e3d9c8"),
        stripe_dark=hexc("d8ccb8"),
        belly=hexc("faf6ee"),
        white=hexc("fcfaf5"),
        nose=hexc("eab0a8"),
        pad=hexc("e5a8a0"),
        inner_ear=hexc("f0b8b0"),
        eye_rim=hexc("8c6258"),
    ),
    "calico": dict(
        base=hexc("f4efe6"),
        base_hi=hexc("faf6ee"),
        dorsal=hexc("f4efe6"),
        stripe=hexc("9e3d12"),
        stripe_dark=hexc("6e280a"),
        belly=hexc("f7f3eb"),
        white=hexc("fcfaf5"),
        nose=hexc("e69a90"),
        pad=hexc("de928a"),
        inner_ear=hexc("ecb0a6"),
        eye_rim=hexc("3b2216"),
        patch_orange=hexc("e27c24"),
        patch_black=hexc("1e1b18"),
    ),
    "grey_tabby": dict(
        base=hexc("8f887d"),
        base_hi=hexc("a69e92"),
        dorsal=hexc("6f6960"),
        stripe=hexc("2a2723"),
        stripe_dark=hexc("181614"),
        belly=hexc("dbd3c5"),
        white=hexc("f5f0e6"),
        nose=hexc("b86a62"),
        pad=hexc("524642"),
        inner_ear=hexc("cfa098"),
        eye_rim=hexc("1c1917"),
    ),
}


def albedo(F: dict[str, np.ndarray], p: np.ndarray, palette: str = "cam") -> np.ndarray:
    """Compose linear-RGB albedo (N,3) from `fields()` and a palette name."""
    P = {k: srgb_to_lin(v) for k, v in PALETTES[palette].items()}
    x, y, z = p[:, 0], p[:, 1], p[:, 2]

    agouti = F["agouti"]
    coat_var = F["coat_var"]

    # Agouti / coat variation stay subtle: strong low-frequency contrast reads as camouflage
    # blotches at gameplay distance (the shell fur adds the fine per-hair variation).
    base = lerp(P["base"], P["base_hi"], 0.35 + 0.30 * smoothstep(-0.45, 0.55, agouti))
    base = base * (1.0 + 0.025 * coat_var[:, None])

    # Richer golden-amber tone along the dorsal saddle and top of head
    dorsal_warmth = smoothstep(0.165, 0.225, z) * smoothstep(-0.20, 0.18, y)
    col = lerp(base, P["dorsal"], 0.48 * dorsal_warmth)

    if palette == "calico":
        n_o = fbm3(x * 7.5 + 1.3, y * 7.5 - 0.8, z * 7.5, 2, 701) + 0.18 * (z - 0.15) * 5
        n_b = fbm3(x * 8.0 - 2.1, y * 8.0 + 1.7, z * 8.0, 2, 709) + 0.15 * (z - 0.15) * 5
        in_o = smoothstep(0.05, 0.18, n_o) * (1 - F["belly"] * 0.85)
        in_b = smoothstep(0.10, 0.22, n_b) * (1 - in_o) * (1 - F["belly"] * 0.85)
        orange_s = lerp(P["patch_orange"], P["stripe"], F["stripe"] * 0.85)
        col = lerp(col, orange_s, in_o)
        col = lerp(col, P["patch_black"], in_b)
    else:
        st = F["stripe"]
        stripe_col = lerp(P["stripe"], P["stripe_dark"], smoothstep(0.45, 0.88, st))
        col = lerp(col, stripe_col, st)

    # Blend warm ivory-cream countershading and bright milk-white domestic markings
    col = lerp(col, P["belly"], F["belly"] * 0.80)
    if "white_zone" in F:
        col = lerp(col, P["white"], F["white_zone"] * 0.92)

    # Delicate dark amber-brown eyelid eyeliner & subtle philtrum/upper-lip definition
    if "lid_rim" in F:
        col = lerp(col, P["eye_rim"], F["lid_rim"] * 0.85)
    if "lip_line" in F:
        col = lerp(col, P["eye_rim"], (F["lip_line"] * 0.48 + F["philtrum"] * 0.42))

    # Inner ear (soft translucent rose-pink with subtle capillary mottling)
    vein = F["vein"]
    ear_c = P["inner_ear"] * (0.94 + 0.08 * vein[:, None])
    col = lerp(col, ear_c, F["inner_ear"] * 0.90)

    # Blossom-pink nose leather with terracotta rim and dark nostrils
    nose_c = lerp(P["nose"], P["nose"] * 0.52, F["nose_rim"] * 0.55)
    nose_c = lerp(nose_c, P["nose"] * 0.16, F["nostril"])
    col = lerp(col, nose_c, F["nose"])

    # Rosy paw pads
    pad_c = P["pad"] * (0.92 + 0.08 * vein[:, None])
    col = lerp(col, pad_c, F["paw_pad"])

    # Strictly internal oral cavity, tongue & teeth
    if "mouth_interior" in F:
        col = lerp(col, srgb_to_lin(hexc("7a2c2c")), F["mouth_interior"])
    col = lerp(col, srgb_to_lin(hexc("d96a6c")), F["is_tongue"])
    col = lerp(col, srgb_to_lin(hexc("f4efe2")), F["is_teeth"])

    return np.clip(col, 0, 1).astype(np.float32)


def roughness(F: dict[str, np.ndarray]) -> np.ndarray:
    r = np.full(len(F["stripe"]), 0.78, dtype=np.float32)
    r = lerp(r, 0.82, F["belly"])
    r = lerp(r, 0.72, F["inner_ear"])
    r = lerp(r, 0.50, F["paw_pad"])
    r = lerp(r, 0.26, F["nose"])
    r = lerp(r, 0.28, F["is_tongue"])
    r = lerp(r, 0.20, F["is_teeth"])
    return r.astype(np.float32)
