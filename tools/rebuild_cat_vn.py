"""Rebuild the Vietnamese Orange Tabby ('Mèo Cam / Mèo Vàng Ta') 3D model and textures.

Runs in standalone Python 3 (NumPy + Pillow) without requiring Blender:
1. Caches original CatBody/CatEyes/CatWhiskers geometry, Cycles-baked AO/shape-normal, and
   2048x2048 UV maps on first run so re-runs are fast and 100% idempotent.
2. Cleans up harsh baked mustache/eye-goggle creases in the face AO & normal map, then evaluates
   upgraded `blender/lib/cat_coat.py` & `blender/lib/cat_tex.py` to generate:
   - cat_albedo.png (2048x2048) + 4 coat variants (black, white, calico, grey_tabby)
   - cat_albedo_4k.jpg (4096x4096)
   - cat_fur_mask.png, cat_fur_flow.png, cat_orm.png, cat_normal.png (2048x2048)
   - cat_eye_iris.png (1024x1024) + 3 eye variants (green, copper, blue)
   - cat_whiskers.png (256x1024)
3. Refines the 3D head & muzzle proportions of CatBody and CatWhiskers in `assets/models/cat/cat.glb`
   in head design space `ph = S.world_to_head(p_bl)` and re-embeds all updated textures.
"""
from __future__ import annotations

import json
import os
import struct
import sys
import time
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "blender", "lib"))

import cat_anatomy as A
import cat_coat as CO
import cat_sdf as S
import cat_tex as TX

GLB_PATH = os.path.join(ROOT, "assets", "models", "cat", "cat.glb")
TEX_DIR = os.path.join(ROOT, "assets", "models", "cat", "textures")
CACHE_DIR = os.path.join(ROOT, "qa", "out", "cat-asset", "cache")


def _read_glb(path: str):
    with open(path, "rb") as f:
        magic, version, total_len = struct.unpack("<4sII", f.read(12))
        assert magic == b"glTF" and version == 2
        j_len, j_type = struct.unpack("<II", f.read(8))
        assert j_type == 0x4E4F534A
        gltf = json.loads(f.read(j_len).decode("utf-8"))
        b_len, b_type = struct.unpack("<II", f.read(8))
        assert b_type == 0x004E4942
        bin_data = f.read(b_len)
    return gltf, bin_data


def _write_glb(path: str, gltf: dict, bv_chunks: list[bytes]):
    order = sorted(range(len(gltf["bufferViews"])), key=lambda i: gltf["bufferViews"][i].get("byteOffset", 0))
    parts = []
    offset = 0
    for i in order:
        chunk = bv_chunks[i]
        gltf["bufferViews"][i]["byteOffset"] = offset
        gltf["bufferViews"][i]["byteLength"] = len(chunk)
        parts.append(chunk)
        offset += len(chunk)
        pad = (4 - (offset % 4)) % 4
        if pad:
            parts.append(b"\x00" * pad)
            offset += pad
    bin_blob = b"".join(parts)
    gltf["buffers"][0]["byteLength"] = len(bin_blob)

    j_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    j_pad = (4 - (len(j_bytes) % 4)) % 4
    if j_pad:
        j_bytes += b" " * j_pad

    total_len = 12 + 8 + len(j_bytes) + 8 + len(bin_blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total_len))
        f.write(struct.pack("<II", len(j_bytes), 0x4E4F534A))
        f.write(j_bytes)
        f.write(struct.pack("<II", len(bin_blob), 0x004E4942))
        f.write(bin_blob)


def _get_acc_np(gltf: dict, bv_chunks: list[bytes], acc_idx: int) -> np.ndarray:
    acc = gltf["accessors"][acc_idx]
    raw = bv_chunks[acc["bufferView"]]
    comp_map = {
        5120: np.int8,
        5121: np.uint8,
        5122: np.int16,
        5123: np.uint16,
        5125: np.uint32,
        5126: np.float32,
    }
    cnt_map = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}
    dt = comp_map[acc["componentType"]]
    k = cnt_map[acc["type"]]
    return np.frombuffer(raw, dtype=dt).reshape(acc["count"], k).copy()


def _set_acc_np(gltf: dict, bv_chunks: list[bytes], acc_idx: int, arr: np.ndarray):
    acc = gltf["accessors"][acc_idx]
    arr_f32 = np.ascontiguousarray(arr, dtype=np.float32)
    bv_chunks[acc["bufferView"]] = arr_f32.tobytes()
    acc["min"] = [float(x) for x in arr_f32.min(axis=0)]
    acc["max"] = [float(x) for x in arr_f32.max(axis=0)]


def ensure_cache(gltf: dict, bv_chunks: list[bytes]):
    os.makedirs(CACHE_DIR, exist_ok=True)
    geom_cache = os.path.join(CACHE_DIR, "orig_glb_geom.npz")
    if not os.path.exists(geom_cache):
        print("Saving original geometry backup to", geom_cache)
        body_pos = _get_acc_np(gltf, bv_chunks, 0)
        body_nrm = _get_acc_np(gltf, bv_chunks, 1)
        body_uv = _get_acc_np(gltf, bv_chunks, 2)
        body_col1 = _get_acc_np(gltf, bv_chunks, 5).astype(np.float32) / 65535.0
        body_joints = _get_acc_np(gltf, bv_chunks, 6)
        body_weights = _get_acc_np(gltf, bv_chunks, 7)
        body_tris = _get_acc_np(gltf, bv_chunks, 8).reshape(-1, 3)

        eye0_pos = _get_acc_np(gltf, bv_chunks, 10)
        eye1_pos = _get_acc_np(gltf, bv_chunks, 17)
        wh_pos = _get_acc_np(gltf, bv_chunks, 24)
        wh_nrm = _get_acc_np(gltf, bv_chunks, 25)
        wh_joints = _get_acc_np(gltf, bv_chunks, 28)
        wh_weights = _get_acc_np(gltf, bv_chunks, 29)

        np.savez_compressed(
            geom_cache,
            body_pos=body_pos,
            body_nrm=body_nrm,
            body_uv=body_uv,
            body_col1=body_col1,
            body_joints=body_joints,
            body_weights=body_weights,
            body_tris=body_tris,
            eye0_pos=eye0_pos,
            eye1_pos=eye1_pos,
            wh_pos=wh_pos,
            wh_nrm=wh_nrm,
            wh_joints=wh_joints,
            wh_weights=wh_weights,
        )

    ao_cache = os.path.join(CACHE_DIR, "orig_ao.npy")
    if not os.path.exists(ao_cache):
        orm_img = np.asarray(Image.open(os.path.join(TEX_DIR, "cat_orm.png")), dtype=np.float32) / 255.0
        np.save(ao_cache, orm_img[..., 0])

    nrm_cache = os.path.join(CACHE_DIR, "orig_normal.png")
    if not os.path.exists(nrm_cache):
        with open(os.path.join(TEX_DIR, "cat_normal.png"), "rb") as fsrc, open(nrm_cache, "wb") as fdst:
            fdst.write(fsrc.read())

    orig_nrm = np.asarray(Image.open(nrm_cache), dtype=np.float32) / 255.0
    return np.load(geom_cache), np.load(ao_cache), orig_nrm


def get_or_rasterize_uv_maps(body_pos_gltf: np.ndarray, body_nrm_gltf: np.ndarray, body_uv: np.ndarray,
                             body_col1: np.ndarray, body_tris: np.ndarray, size: int = 2048) -> dict[str, np.ndarray]:
    uv_cache = os.path.join(CACHE_DIR, f"uv_maps_{size}.npz")
    if os.path.exists(uv_cache):
        print(f"  Loading cached {size}x{size} UV maps from {uv_cache}")
        d = np.load(uv_cache)
        return {"pos": d["pos"], "nrm": d["nrm"], "part": d["part"]}

    t0 = time.time()
    P_bl = np.stack([body_pos_gltf[:, 0], -body_pos_gltf[:, 2], body_pos_gltf[:, 1]], axis=-1).astype(np.float32)
    N_bl = np.stack([body_nrm_gltf[:, 0], -body_nrm_gltf[:, 2], body_nrm_gltf[:, 1]], axis=-1).astype(np.float32)
    N_bl /= np.linalg.norm(N_bl, axis=-1, keepdims=True) + 1e-9
    N_enc = N_bl * 0.5 + 0.5
    Q_id = body_col1[:, :3].astype(np.float32)

    pos_map = np.zeros((size, size, 4), dtype=np.float32)
    nrm_map = np.zeros((size, size, 4), dtype=np.float32)
    part_map = np.zeros((size, size, 4), dtype=np.float32)

    uv_px = body_uv * float(size) - 0.5
    v0 = uv_px[body_tris[:, 0]]
    v1 = uv_px[body_tris[:, 1]]
    v2 = uv_px[body_tris[:, 2]]

    xmin = np.clip(np.floor(np.minimum(np.minimum(v0[:, 0], v1[:, 0]), v2[:, 0])).astype(np.int32), 0, size - 1)
    xmax = np.clip(np.ceil(np.maximum(np.maximum(v0[:, 0], v1[:, 0]), v2[:, 0])).astype(np.int32), 0, size - 1)
    ymin = np.clip(np.floor(np.minimum(np.minimum(v0[:, 1], v1[:, 1]), v2[:, 1])).astype(np.int32), 0, size - 1)
    ymax = np.clip(np.ceil(np.maximum(np.maximum(v0[:, 1], v1[:, 1]), v2[:, 1])).astype(np.int32), 0, size - 1)

    denom = (v1[:, 1] - v2[:, 1]) * (v0[:, 0] - v2[:, 0]) + (v2[:, 0] - v1[:, 0]) * (v0[:, 1] - v2[:, 1])
    valid = np.abs(denom) > 1e-8
    inv_denom = np.where(valid, 1.0 / np.where(valid, denom, 1.0), 0.0)

    p0, p1, p2 = P_bl[body_tris[:, 0]], P_bl[body_tris[:, 1]], P_bl[body_tris[:, 2]]
    n0, n1, n2 = N_enc[body_tris[:, 0]], N_enc[body_tris[:, 1]], N_enc[body_tris[:, 2]]
    q0, q1, q2 = Q_id[body_tris[:, 0]], Q_id[body_tris[:, 1]], Q_id[body_tris[:, 2]]

    for t in np.nonzero(valid)[0]:
        x0, x1 = xmin[t], xmax[t]
        y0, y1 = ymin[t], ymax[t]
        ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1]
        x2d, y2d = v2[t, 0], v2[t, 1]
        dx = xs - x2d
        dy = ys - y2d
        w0 = ((v1[t, 1] - y2d) * dx + (x2d - v1[t, 0]) * dy) * inv_denom[t]
        w1 = ((y2d - v0[t, 1]) * dx + (v0[t, 0] - x2d) * dy) * inv_denom[t]
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if not inside.any():
            continue
        w0i = w0[inside][:, None]
        w1i = w1[inside][:, None]
        w2i = w2[inside][:, None]
        yi, xi = ys[inside], xs[inside]

        pos_map[yi, xi, :3] = w0i * p0[t] + w1i * p1[t] + w2i * p2[t]
        pos_map[yi, xi, 3] = 1.0
        nrm_map[yi, xi, :3] = w0i * n0[t] + w1i * n1[t] + w2i * n2[t]
        nrm_map[yi, xi, 3] = 1.0
        part_map[yi, xi, :3] = w0i * q0[t] + w1i * q1[t] + w2i * q2[t]
        part_map[yi, xi, 3] = 1.0

    np.savez_compressed(uv_cache, pos=pos_map, nrm=nrm_map, part=part_map)
    cov_pct = (pos_map[..., 3] > 0.5).mean() * 100.0
    print(f"  Rasterized & cached {size}x{size} UV maps in {time.time() - t0:.2f}s (coverage: {cov_pct:.1f}%)")
    return {"pos": pos_map, "nrm": nrm_map, "part": part_map}


def build_dilate_index(cov: np.ndarray, iters: int = 16) -> tuple[np.ndarray, np.ndarray]:
    """Precompute nearest-covered-pixel indices once so dilating any (H,W,C) image takes <0.02s."""
    H, W = cov.shape
    iy, ix = np.mgrid[0:H, 0:W].astype(np.int32)
    m = cov.copy()
    for _ in range(iters):
        new_m = m.copy()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            sm = np.roll(np.roll(m, dy, 0), dx, 1)
            fill = (~new_m) & sm
            if fill.any():
                iy[fill] = np.roll(np.roll(iy, dy, 0), dx, 1)[fill]
                ix[fill] = np.roll(np.roll(ix, dy, 0), dx, 1)[fill]
                new_m |= fill
        m = new_m
    return iy, ix


def fast_dilate(img: np.ndarray, iy: np.ndarray, ix: np.ndarray) -> np.ndarray:
    return img[iy, ix]


def save_png_pil(path: str, img: np.ndarray):
    arr = np.clip(np.rint(np.asarray(img, dtype=np.float32) * 255.0), 0, 255).astype(np.uint8)
    Image.fromarray(arr).save(path, format="PNG", compress_level=3)


def eval_fields(maps: dict[str, np.ndarray], palettes=("cam", "black", "white", "calico", "grey_tabby"), chunk=800_000):
    t0 = time.time()
    pos, nrm, part = maps["pos"], maps["nrm"], maps["part"]
    H, W = pos.shape[:2]
    cov = pos[..., 3] > 0.5
    idx = np.nonzero(cov.ravel())[0]
    P_all = pos[..., :3].reshape(-1, 3)
    N_all = nrm[..., :3].reshape(-1, 3) * 2.0 - 1.0
    N_all /= np.linalg.norm(N_all, axis=1, keepdims=True) + 1e-9
    Q_all = part[..., :3].reshape(-1, 3)
    out = {}
    for i in range(0, len(idx), chunk):
        ii = idx[i:i + chunk]
        P = P_all[ii].astype(np.float64)
        N = N_all[ii].astype(np.float64)
        F = CO.fields(P, N, Q_all[ii])
        res = {}
        for pal in palettes:
            res["albedo_" + pal] = CO.albedo(F, P, pal)
        res["rough"] = CO.roughness(F)[:, None]
        res["mask"] = np.stack([F["fur_len"], F["fur_den"], F["stripe"]], 1)
        res["flow"] = F["flow"]
        for k, v in res.items():
            if k not in out:
                out[k] = np.zeros((H * W, v.shape[1]), np.float32)
            out[k][ii] = v
    print(f"  Evaluated coat fields & {len(palettes)} palettes in {time.time() - t0:.2f}s")
    return {k: v.reshape(H, W, -1) for k, v in out.items()}, cov


def _sstep(a, b, v):
    t = np.clip((v - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _head_design_disp(ph: np.ndarray, jaw_w: np.ndarray, mask_mult: np.ndarray) -> np.ndarray:
    """Compute 3D sculpt refinement delta `d_ph` in head design space `ph = (hx, hy, hz)`
    (where `hf = -hy` is forward and `hz` is up)."""
    hx, hy, hz = ph[:, 0], ph[:, 1], ph[:, 2]
    hf = -hy
    ahx = np.abs(hx)
    sx = np.sign(hx)
    d = np.zeros_like(ph)

    upper_w = np.clip(1.0 - jaw_w * 2.2, 0.0, 1.0) * mask_mult
    lower_w = _sstep(0.15, 0.65, jaw_w) * mask_mult

    # 0. Eliminate the periorbital 'swimming-goggle' ridge (r=9.5..12.2mm) and moat (r=12.2..16.5mm)
    ed2 = np.sqrt((ahx - abs(A.EYE_L[0])) ** 2 + (hz - A.EYE_L[2]) ** 2)
    w_eye_front = _sstep(0.186, 0.198, hf) * upper_w
    goggle_ridge = np.exp(-((ed2 - 0.0108) / 0.0018) ** 2) * w_eye_front
    goggle_moat = np.exp(-((ed2 - 0.0136) / 0.0024) ** 2) * w_eye_front
    d[:, 1] += 0.0024 * goggle_ridge   # push protruding goggle ring back (+hy)
    d[:, 1] -= 0.0028 * goggle_moat    # fill in sunken orbital moat forward (-hy)

    # 1. Tuck in the overly wide, shelf-like zygomatic cheekbones below the outer eye corners
    w_zygo = (
        _sstep(0.018, 0.025, ahx)
        * _sstep(0.172, 0.186, hf)
        * (1.0 - _sstep(0.210, 0.220, hf))
        * _sstep(0.222, 0.231, hz)
        * (1.0 - _sstep(0.246, 0.253, hz))
    )
    d[:, 0] -= sx * 0.0036 * w_zygo * upper_w
    d[:, 2] -= 0.0008 * w_zygo * upper_w

    # 2. Round and widen the upper cranium, forehead & temples above/behind the eyes
    w_dome = (
        _sstep(0.246, 0.256, hz)
        * (1.0 - _sstep(0.274, 0.282, hz))
        * _sstep(0.148, 0.165, hf)
        * (1.0 - _sstep(0.202, 0.214, hf))
    )
    w_temple = w_dome * _sstep(0.010, 0.020, ahx) * (1.0 - _sstep(0.030, 0.038, ahx))
    d[:, 2] += 0.0040 * w_dome * upper_w
    d[:, 0] += sx * 0.0028 * w_temple * upper_w
    d[:, 1] -= 0.0018 * w_dome * _sstep(0.182, 0.196, hf) * upper_w

    # 3. Gently round the omega whisker pads & soften the lateral lip commissure without creating an underbite
    w_commissure = (
        _sstep(0.186, 0.196, hf)
        * (1.0 - _sstep(0.208, 0.214, hf))
        * _sstep(0.212, 0.217, hz)
        * (1.0 - _sstep(0.228, 0.234, hz))
        * _sstep(0.010, 0.014, ahx)
    )
    d[:, 0] -= sx * 0.0018 * w_commissure * upper_w
    d[:, 2] += 0.0012 * w_commissure * upper_w

    # 4. Gently close the lower-jaw side gap while keeping the chin behind the upper whisker pads
    w_jaw_close = _sstep(0.178, 0.196, hf) * lower_w
    w_jaw_narrow = _sstep(0.168, 0.186, hf) * (1.0 - _sstep(0.208, 0.218, hf)) * _sstep(0.008, 0.014, ahx) * lower_w
    d[:, 2] += 0.0022 * w_jaw_close
    d[:, 0] -= sx * 0.0020 * w_jaw_narrow

    return d


def strand_components(tris: np.ndarray, n: int) -> np.ndarray:
    """Connected-component label per vertex (union-find over triangle edges)."""
    parent = np.arange(n)

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for t in tris:
        r0 = find(int(t[0]))
        for v in t[1:]:
            r = find(int(v))
            if r != r0:
                parent[r] = r0
    return np.array([find(i) for i in range(n)])


def rigid_strand_disp(wh: np.ndarray, wh_tris: np.ndarray, d: np.ndarray, body: np.ndarray) -> np.ndarray:
    """Per-strand constant displacement = the displacement at the strand's root (the vertex
    closest to the body surface)."""
    labels = strand_components(wh_tris, len(wh))
    out = np.zeros_like(d)
    for lab in np.unique(labels):
        idx = np.nonzero(labels == lab)[0]
        dist = np.linalg.norm(wh[idx, None, :] - body[None, ::4, :], axis=-1).min(axis=1)
        out[idx] = d[idx[np.argmin(dist)]]
    return out


def sculpt_vn_cat_head(body_pos: np.ndarray, body_nrm: np.ndarray, body_col1: np.ndarray,
                       body_joints: np.ndarray, body_weights: np.ndarray, body_tris: np.ndarray,
                       eye0_pos: np.ndarray, eye1_pos: np.ndarray,
                       wh_pos: np.ndarray, wh_joints: np.ndarray, wh_weights: np.ndarray,
                       wh_tris: np.ndarray):
    p_g = body_pos.copy()
    wh_g = wh_pos.copy()

    is_ear = body_col1[:, 0] > 0.3
    is_teeth = body_col1[:, 1] > 0.3
    is_tongue = body_col1[:, 2] > 0.3
    is_skin = ~(is_ear | is_teeth | is_tongue)

    eye_verts = np.concatenate([eye0_pos, eye1_pos], axis=0)
    head_idx = np.nonzero(p_g[:, 2] > 0.11)[0]
    eye_dist = np.full(len(p_g), 1.0, dtype=np.float32)
    d_mat = np.linalg.norm(p_g[head_idx, None, :] - eye_verts[None, :, :], axis=-1)
    eye_dist[head_idx] = d_mat.min(axis=1)
    eye_safe = _sstep(0.0014, 0.0030, eye_dist)

    jaw_w = np.sum(np.where(body_joints == 20, body_weights, 0.0), axis=1)

    hm = is_skin & (p_g[:, 2] > 0.11)
    p_bl = np.stack([p_g[hm, 0], -p_g[hm, 2], p_g[hm, 1]], axis=-1).astype(np.float64)
    ph = S.world_to_head(p_bl)
    d_ph = _head_design_disp(ph, jaw_w[hm], eye_safe[hm])
    d_bl = A.head_to_world_np(ph + d_ph) - A.head_to_world_np(ph)
    p_g[hm, 0] += d_bl[:, 0].astype(np.float32)
    p_g[hm, 1] += d_bl[:, 2].astype(np.float32)
    p_g[hm, 2] -= d_bl[:, 1].astype(np.float32)

    # Fair (Laplacian smooth) on the welded 3D vertex graph so UV seams never split!
    _, uniq_idx, uniq_inv = np.unique(np.round(body_pos, 6), axis=0, return_index=True, return_inverse=True)
    u_pos = p_g[uniq_idx].copy()
    u_orig_x0 = np.abs(body_pos[uniq_idx, 0]) < 1e-5

    full_ph = np.zeros_like(p_g, dtype=np.float64)
    full_ph[hm] = ph
    u_ph = full_ph[uniq_idx]
    ahx_f = np.abs(u_ph[:, 0])
    hf_f = -u_ph[:, 1]
    hz_f = u_ph[:, 2]
    u_jaw_w = jaw_w[uniq_idx]
    u_eye_safe = eye_safe[uniq_idx]
    u_hm = hm[uniq_idx]

    ed2_f = np.sqrt((ahx_f - abs(A.EYE_L[0])) ** 2 + (hz_f - A.EYE_L[2]) ** 2)
    nose_keep = (1.0 - _sstep(0.0055, 0.0085, ahx_f)) * _sstep(0.229, 0.232, hz_f) * (1.0 - _sstep(0.240, 0.243, hz_f)) * _sstep(0.210, 0.214, hf_f)
    orb_fair = _sstep(0.0075, 0.0092, ed2_f) * (1.0 - _sstep(0.0175, 0.0220, ed2_f)) * _sstep(0.180, 0.192, hf_f) * np.clip(1.0 - u_jaw_w * 2.5, 0.0, 1.0)
    lip_fair = _sstep(0.182, 0.194, hf_f) * (1.0 - _sstep(0.214, 0.220, hf_f)) * _sstep(0.213, 0.217, hz_f) * (1.0 - _sstep(0.230, 0.235, hz_f)) * _sstep(0.004, 0.008, ahx_f) * np.clip(1.0 - u_jaw_w * 2.5, 0.0, 1.0)
    fair_w = (np.maximum(orb_fair, lip_fair * 0.65) * u_eye_safe * (1.0 - nose_keep) * u_hm.astype(np.float64)).astype(np.float32)[:, None]

    u_tris = uniq_inv[body_tris]
    edges = np.concatenate([
        u_tris[:, [0, 1]], u_tris[:, [1, 0]],
        u_tris[:, [1, 2]], u_tris[:, [2, 1]],
        u_tris[:, [2, 0]], u_tris[:, [0, 2]],
    ], axis=0)
    deg = np.zeros((len(u_pos), 1), dtype=np.float32)
    np.add.at(deg, edges[:, 0], 1.0)
    deg = np.maximum(deg, 1.0)
    for _ in range(16):
        nb_sum = np.zeros_like(u_pos)
        np.add.at(nb_sum, edges[:, 0], u_pos[edges[:, 1]])
        nb_avg = nb_sum / deg
        u_pos = u_pos + 0.55 * fair_w * (nb_avg - u_pos)
        u_pos[u_orig_x0, 0] = 0.0

    p_g = u_pos[uniq_inv]

    wh_hm = wh_g[:, 2] > 0.14
    wh_bl = np.stack([wh_g[wh_hm, 0], -wh_g[wh_hm, 2], wh_g[wh_hm, 1]], axis=-1).astype(np.float64)
    wh_ph = S.world_to_head(wh_bl)
    wh_jaw_w = np.sum(np.where(wh_joints[wh_hm] == 20, wh_weights[wh_hm], 0.0), axis=1)
    wh_d_ph = _head_design_disp(wh_ph, wh_jaw_w, np.ones(len(wh_ph), dtype=np.float64))
    wh_d_bl = A.head_to_world_np(wh_ph + wh_d_ph) - A.head_to_world_np(wh_ph)
    wh_d = np.zeros_like(wh_g)
    wh_d[wh_hm, 0] = wh_d_bl[:, 0]
    wh_d[wh_hm, 1] = wh_d_bl[:, 2]
    wh_d[wh_hm, 2] = -wh_d_bl[:, 1]
    # Move each whisker strand rigidly with the skin under its root: the head field has ~1 mm
    # smoothstep edges, so displacing every strand vertex independently kinks the strands.
    wh_g = wh_g + rigid_strand_disp(wh_g, wh_tris, wh_d, p_g)

    # Compute welded vertex normals across `uniq_inv` so UV seams are 100% smooth
    v0, v1, v2 = p_g[body_tris[:, 0]], p_g[body_tris[:, 1]], p_g[body_tris[:, 2]]
    fn = np.cross(v1 - v0, v2 - v0)
    u_vn = np.zeros_like(u_pos)
    np.add.at(u_vn, u_tris[:, 0], fn)
    np.add.at(u_vn, u_tris[:, 1], fn)
    np.add.at(u_vn, u_tris[:, 2], fn)
    u_vn[u_orig_x0, 0] = 0.0
    u_vn /= np.linalg.norm(u_vn, axis=1, keepdims=True) + 1e-9
    vn = u_vn[uniq_inv]

    mod_amt = np.linalg.norm(p_g - body_pos, axis=1)
    blend_n = np.clip(mod_amt / 0.0012, 0.0, 1.0)[:, None] * is_skin[:, None]
    new_nrm = body_nrm * (1.0 - blend_n) + vn * blend_n
    new_nrm /= np.linalg.norm(new_nrm, axis=1, keepdims=True) + 1e-9

    return p_g, new_nrm, wh_g


def main():
    t_start = time.time()
    print("=== Rebuilding Vietnamese Orange Tabby ('Mèo Vàng Ta') 3D Asset ===")
    gltf, bin_data = _read_glb(GLB_PATH)
    bv_chunks = [
        bin_data[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
        for bv in gltf["bufferViews"]
    ]

    cache, orig_ao, orig_nrm = ensure_cache(gltf, bv_chunks)
    body_pos = cache["body_pos"]
    body_nrm = cache["body_nrm"]
    body_uv = cache["body_uv"]
    body_col1 = cache["body_col1"]
    body_joints = cache["body_joints"]
    body_weights = cache["body_weights"]
    body_tris = cache["body_tris"]
    eye0_pos = cache["eye0_pos"]
    eye1_pos = cache["eye1_pos"]
    wh_pos = cache["wh_pos"]
    wh_joints = cache["wh_joints"]
    wh_weights = cache["wh_weights"]

    geom_only = "--geom-only" in sys.argv
    # --tex-only: regenerate textures from the GLB's current (already sculpted) geometry and its
    # current AO/normal maps; no face clean-up pass and no geometry sculpt (both are already applied).
    tex_only = "--tex-only" in sys.argv
    if not geom_only:
        # 1. Load or rasterize 2048x2048 UV maps from original rest pose
        S2 = 2048
        maps2 = get_or_rasterize_uv_maps(body_pos, body_nrm, body_uv, body_col1, body_tris, S2)
        res2, cov2 = eval_fields(maps2, palettes=("cam", "black", "white", "calico", "grey_tabby"))
        iy, ix = build_dilate_index(cov2, 16)

        # 2. Clean up harsh baked mustache/eye-goggle creases in face AO and face normal map
        y_bl = maps2["pos"][..., 1]
        is_skin_map = (1.0 - maps2["part"][..., :3].max(axis=-1)) * cov2.astype(np.float32)
        face_w = _sstep(-0.135, -0.175, y_bl) * is_skin_map

        # Smooth AO on outer face skin so old baked mustache/eye-socket trenches don't darken the face
        w_ao = (face_w * (0.0 if tex_only else 0.88)).astype(np.float32)
        ao = (orig_ao * (1.0 - w_ao) + np.maximum(orig_ao, 0.90) * w_ao).astype(np.float32)

        # Smooth normal map on the face so our new 3D vertex normals control the cheek/muzzle shading cleanly
        flat_nrm = np.array([0.5, 0.5, 1.0], dtype=np.float32)
        w_nrm = (face_w * (0.0 if tex_only else 0.78))[..., None].astype(np.float32)
        nrm_clean = orig_nrm[..., :3] * (1.0 - w_nrm) + flat_nrm * w_nrm
        n_vec = nrm_clean * 2.0 - 1.0
        n_vec /= np.linalg.norm(n_vec, axis=-1, keepdims=True) + 1e-9
        save_png_pil(os.path.join(TEX_DIR, "cat_normal.png"), n_vec * 0.5 + 0.5)

        # 3. Fur flow map in tangent space
        nrm_obj = maps2["nrm"][..., :3] * 2.0 - 1.0
        T, B, texel, ok = TX.tangent_frames(maps2["pos"], nrm_obj, cov2)
        fl = res2["flow"]
        fts = np.stack([np.sum(fl * T, -1), np.sum(fl * B, -1)], -1)
        fts /= np.linalg.norm(fts, axis=-1, keepdims=True) + 1e-9
        flow_img = np.concatenate([fts * 0.5 + 0.5, np.full(fts.shape[:2] + (1,), 0.5, dtype=np.float32)], -1)
        flow_img[~cov2] = (0.5, 0.5, 0.5)
        save_png_pil(os.path.join(TEX_DIR, "cat_fur_flow.png"), fast_dilate(flow_img, iy, ix))

        # 4. ORM (AO + roughness + metallic=0) and Fur Mask (length, density, stripe)
        rough = res2["rough"][..., 0]
        orm = np.stack([ao, rough, np.zeros_like(ao)], -1)
        save_png_pil(os.path.join(TEX_DIR, "cat_orm.png"), fast_dilate(orm, iy, ix))
        save_png_pil(os.path.join(TEX_DIR, "cat_fur_mask.png"), fast_dilate(res2["mask"], iy, ix))

        # 5. Albedo maps (2048 PNGs for all 5 palettes + 4096 JPEG hero albedo)
        aoc = (0.68 + 0.32 * ao)[..., None]
        cam_srgb_2k = None
        for pal, fname in (
            ("cam", "cat_albedo.png"),
            ("black", "cat_albedo_black.png"),
            ("white", "cat_albedo_white.png"),
            ("calico", "cat_albedo_calico.png"),
            ("grey_tabby", "cat_albedo_grey_tabby.png"),
        ):
            alb_srgb = fast_dilate(TX.lin_to_srgb(res2["albedo_" + pal] * aoc), iy, ix)
            save_png_pil(os.path.join(TEX_DIR, fname), alb_srgb)
            if pal == "cam":
                cam_srgb_2k = alb_srgb

        arr_2k_u8 = np.clip(np.rint(cam_srgb_2k * 255.0), 0, 255).astype(np.uint8)
        img_4k = Image.fromarray(arr_2k_u8).resize((4096, 4096), resample=Image.Resampling.LANCZOS)
        img_4k.save(os.path.join(TEX_DIR, "cat_albedo_4k.jpg"), format="JPEG", quality=92, subsampling=0)

        # 6. Eye iris & Whisker textures
        iris_cam = TX.iris_texture(1024, palette="cam")
        save_png_pil(os.path.join(TEX_DIR, "cat_eye_iris.png"), iris_cam)
        for pal in ("green", "copper", "blue"):
            save_png_pil(os.path.join(TEX_DIR, f"cat_eye_iris_{pal}.png"), TX.iris_texture(512, palette=pal))
        save_png_pil(os.path.join(TEX_DIR, "cat_whiskers.png"), TX.whisker_atlas(256, 1024))

    # 7. Refine 3D head/muzzle sculpt on CatBody and CatWhiskers in head design space
    if tex_only:
        new_body_pos, new_body_nrm, new_wh_pos = body_pos, body_nrm, wh_pos
    else:
        new_body_pos, new_body_nrm, new_wh_pos = sculpt_vn_cat_head(
            body_pos, body_nrm, body_col1, body_joints, body_weights, body_tris,
            eye0_pos, eye1_pos, wh_pos, wh_joints, wh_weights,
            _get_acc_np(gltf, bv_chunks, 30).reshape(-1, 3)
        )
    _set_acc_np(gltf, bv_chunks, 0, new_body_pos)
    _set_acc_np(gltf, bv_chunks, 1, new_body_nrm)
    _set_acc_np(gltf, bv_chunks, 24, new_wh_pos)

    # 8. Re-embed updated textures into cat.glb
    img_file_map = {
        "cat_normal": os.path.join(TEX_DIR, "cat_normal.png"),
        "cat_orm": os.path.join(TEX_DIR, "cat_orm.png"),
        "cat_albedo_4k": os.path.join(TEX_DIR, "cat_albedo_4k.jpg"),
        "cat_eye_iris": os.path.join(TEX_DIR, "cat_eye_iris.png"),
        "cat_whiskers": os.path.join(TEX_DIR, "cat_whiskers.png"),
    }
    for im in gltf["images"]:
        nm = im.get("name", "")
        if nm in img_file_map:
            with open(img_file_map[nm], "rb") as f:
                bv_chunks[im["bufferView"]] = f.read()

    _write_glb(GLB_PATH, gltf, bv_chunks)
    print(f"=== Done in {time.time() - t_start:.2f}s! Updated {GLB_PATH} and {TEX_DIR} ===")


if __name__ == "__main__":
    main()
