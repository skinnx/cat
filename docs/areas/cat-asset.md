# cat-asset — Cam, the orange tabby (`assets/models/cat/cat.glb`)

The hero asset: a fully procedural, reproducible pipeline (Blender 5.2 + numpy) that sculpts,
retopologises, UV-unwraps, rigs, skins, textures and animates Cam, and exports one glTF.

![hero](../gallery/cat-asset_hero.jpg)

Gallery: `docs/gallery/cat-asset_hero.jpg` (Cycles strand-fur preview, sit pose), `cat-asset_godot_walk.jpg`
(in-engine, `walk` playing, no shell fur), `cat-asset_anim_loco.jpg` (gait contact sheet), `cat-asset_coats.jpg`
(the 4 NPC coat variants in Godot).

## What was built

| Part | Details |
|---|---|
| **Anatomy** | `blender/lib/cat_anatomy.py` — measured landmarks: nose→tail-root 0.46 m, withers 0.25 m, tail 0.28 m (8 segments), head ≈ 0.09 m wide, ears ≈ 0.047 m. Digitigrade fore/hind limbs from feline segment ratios (scapula/humerus/radius/metacarpus, femur/tibia/metatarsus), elbow behind the chest, visible hock + calcaneus. Head authored in a "design space" placed by a similarity transform (scale 1.13, +7° pitch, lift) plus a **muzzle warp** (`MUZZLE_PUSH`, `LOWER_FACE_LIFT`: longer nose/whisker pads, shorter lower face, eyes masked out). Eyeball Ø 21.2 mm sunk into the orbit; palpebral fissure 16.9 × 10.6 mm, flatter upper lid (`EYE_APERTURE_UP_FRAC` 0.46), 13° almond slant, and the lid opening faces 14° further out than the gaze (`EYE_APERTURE_OUT_DEG`) so the cornea shows in profile. Real-world targets are constants in `REFERENCE_HEAD`; `python3 blender/cat/dev_head_measure.py` measures the SDF against them. |
| **Sculpt (SDF)** | `cat_sdf.py` — ~70 smooth-blended analytic primitives (ribcage, sternum keel, epaxial muscles, withers, croup, primordial pouch, scapula plates, triceps, olecranon, carpal pad, dewclaw, haunch, hamstrings, calf, Achilles, hock, 4 toes + toe beans per paw, cranium/occiput/brow/zygomatic/jowls, nose bridge, whisker pads, upper-lip flews, inverted-triangle nose leather, mandible/chin/lower lip). Carved: mouth (a thin air shell around the lower jaw under an upper-lip *curtain* + flews that hang in front of the lower lip, so the closed lip line opens downwards and is hidden from the front; jaw modelled 4° open), almond eye apertures with rounded canthi cut through a periorbital fill (lids overlap the cornea; the eyeball–lid clearance slit exists only just behind the lid margins, deeper slits folded the game mesh into flaps), nostrils, philtrum. Meshed with openvdb (0.8 mm voxels, ~560 k quads) = the normal-bake source `CatHigh`. |
| **Game mesh** `CatBody` | `cat_topo.py` — QuadriFlow on the +X half (density warp: face ×1.55, eyes ×1.25, paws ×1.35), mirrored & welded (watertight, exactly symmetric), Newton-projected back on the SDF with tangential relaxation: **~17.5 k quads** skin + parametric ears (solidified cartilage shells with cavity and Henry's pocket), teeth (canines + incisors) and tongue → **≈ 43.4 k tris total** (contract 25–45 k; checked by the test). One material `CatFur`. |
| **UVs** | `cat_uv.py` — islands cut where fur hides seams: head mask (neck ring + under-chin cut), torso as left/right flank pelts (dorsal + ventral midline), legs below elbow/knee (medial-posterior cut, Dijkstra paths), paw caps, tail (underside cut), mouth interior, eye sockets, ears split at the rim, teeth, tongue. Minimum-stretch unwrap, uniform texel density then importance scaling (face ×1.35, paws ×1.15, hidden interiors ×0.25–0.6). Body ≈ 6.7 k px/m, face ≈ 9.1 k px/m at 4096; coverage 0.76. |
| **Eyes** `CatEyes` | 2 eyeballs: sclera sphere + recessed, slightly domed iris disc (real parallax under the cornea) and a separate bulging cornea cap (+1.1 mm) continuing as a tear film over the sclera. Surface 0 `CatEye_Iris` (procedural iris: radial fibres, crypts, jagged collarette, green-gold → amber gradient, dark limbal ring, lens-shaped vertical slit pupil), surface 1 `CatEye_Cornea` (alpha-blended, glossy). Eyes are skinned to `eye_L/R` bones. |
| **Whiskers** `CatWhiskers` | 12 mystacial per side in 4 rows (curved, tapered, crossed alpha-clipped ribbons, 5–8 cm), 3 superciliary + 2 genal per side, 3 chin, 3 carpal per foreleg, and 5 soft, low-alpha ear-furnishing cards per ear lying in the lower cavity (the earlier upright cards read as white wires/combs across the ears). One alpha-clip atlas `cat_whiskers.png`. |
| **Rig** `CatRig` | 52 bones, all contract names + extras: `neck_02`, `tail_07/08`, `scapula_L/R`, `finger_L/R`, `ear_tip_L/R`, `eyelid_low_L/R`, `eye_L/R`, `tongue_01/02`, `whisker_L/R`, sockets `mouth_socket`, `fpp_eye`. All bones are deform bones (sockets carry no weights) so glTF keeps them. |
| **Skinning** | Bone-heat on a ×10 scaled skin-only copy (the heat solver fails at real scale / with the separate shells), then procedural regions: jaw (below the lip line, in front of the hinge, fading at the commissures), upper/lower eyelids (lid shell around the aperture), whisker pads, ear base/tip, teeth/tongue; Laplacian smoothing, 4 influences. Test poses (neck twist, folded foreleg, spine + tail curl, open jaw, blink) show no tearing. |
| **Textures** (`assets/models/cat/textures/`) | All computed in numpy from rest-pose position/normal maps baked into UV space, so the coat is a 3D pattern and UV seams never break it: `cat_albedo_4k.jpg` (4096, embedded), `cat_albedo.png` (2048), `cat_normal.png` (high→low SDF shape bake + fur-strand micro-normal along the flow, RNM-blended), `cat_orm.png` (AO bake / roughness / 0), `cat_fur_mask.png` (R length, G density, B stripe mask), `cat_fur_flow.png` (tangent-space comb direction, same frame as the normal map), NPC coats `cat_albedo_{black,white,calico,grey_tabby}.png`, iris `cat_eye_iris.png` + `_green/_copper/_blue`, `cat_whiskers.png`. |
| **Coat design** (`cat_coat.py`) | Orange mackerel tabby: dorsal stripe; bars perpendicular to the spine swept backwards down the flanks, breaking into dashes toward the cream belly; hints of shoulder/thigh swirls; necklaces; barred outer legs; ringed tail with darker tip; forehead "M", crown lines to the nape, mascara line and cheek swirl; dark eyeliner + narrow pale eye ring; whisker-follicle dots; cream-white chin, muzzle, bib, belly, inner legs, toes; pink nose leather with darker rim and nostrils; rose toe beans + carpal pad; dark lip line; mouth, palate ridges, tongue, teeth; pink inner ears with pale hair. Every marking edge is feathered along the hair direction by anisotropic strand noise (≈0.4 mm × 9 mm). |
| **Animation** (`cat_anim.py`, `cat_clips.py`) | 32 contract clips, in place, 30 fps. Armature-space solver: pelvis/spine distribution, head stabilisation (world-space head target, residual shared by neck/neck_02/head), forelegs with automatic scapular rotation + glide and carpal flex, hind legs with **pantograph IK** (femur ∥ metatarsus → 2-bone problem, knee forward, hock back), tail travelling waves, ear flicks, blinks, breathing. All clips are authored in 30 fps frames but **keyed at 120 Hz** (`cat_anim.KEY_RATE`), and the import option `animation/fps` is 120 (`configure_import.py`): Godot re-bakes glTF tracks at that rate, and at its default 30 Hz linear interpolation made the gallop's planted paws sink ~2 cm and slide. Gaits: walk = lateral sequence LH→LF→RH→RF (0.7 m/s, 0.5 s stride, duty 0.60), trot = diagonal pairs (1.6 m/s, duty 0.46), run = rotary gallop LH→RH→RF→LF (4.5 m/s, 4 Hz strides of 1.125 m, duty fore 0.30 / hind 0.28) with gathered + extended suspension and ±24° spine flexion; swing paws leave and meet the ground at stance speed (Hermite swing), sneak = low, duty 0.72 (0.45 m/s), balance_walk = single track with a balancing tail (0.40 m/s). Stance paws move at exactly the gait speed → no foot sliding; per-leg reach is checked (≤ 0.98 in all ground-contact clips). |

## Animation list (frames @30 fps, L = loops)
idle 120 L · idle_look 150 L · walk 30 L · trot 20 L · run 16 L · sneak 40 L · sneak_idle 90 L ·
jump_crouch 12 · jump_up 10 · fall 20 L · land 12 · land_hard 24 · sit_down 30 · sit_idle 120 L ·
stand_up 24 · lie_down 45 · sleep 150 L · groom 96 L · meow 24 · hiss 36 · swipe 15 · scratch 30 L ·
climb 18 L · turn_left_90 20 · turn_right_90 20 · drink 40 L · eat 40 L · knead 32 L · stretch 64 ·
balance_walk 40 L · pickup 22 · knock 24.

Conventions the controller must know: turns assume a **linear** ±90° yaw over the clip; climb wall at
Godot local z = +0.075 and 0.5 m/s; scratch surface at z = +0.12; `pickup` ends with the jaw closed on
an item at `mouth_socket`. Loop modes are set by the import options (`configure_import.py`).

## How to regenerate
```bash
tools/blender_run.sh blender/cat/build_cat.py                    # full build (~25 min on 4 CPUs)
tools/blender_run.sh blender/cat/build_cat.py -- --from tex      # textures + anims + export only
tools/blender_run.sh blender/cat/build_cat.py -- --only anim --qa  # rebuild clips + QA frames
python3 blender/cat/configure_import.py && tools/godot_import.sh # import options (loops, compression)
tools/run_tests.sh cat_asset                                     # contract test
tools/blender_run.sh blender/cat/render_hero.py -- 1500000 1600x1000 96 sit   # Cycles strand-fur hero
```
Stages cache to `qa/out/cat-asset/cache/stage_*.blend` (`qa/out/cat-asset/.gdignore` keeps Godot's importer away from them). Dev helpers: `dev_shape.py` (SDF clay views),
`dev_anim.py` (render selected clips), `dev_probe.py` (pose landmarks + IK reach, no render).
Source scene for humans: `blender/cat/cat.blend` (dense sculpt mesh removed to stay small).
In-engine check: `assets/models/cat/preview/cat_preview.tscn` (plays `walk`; `call=pose_idle|pose_sit|
pose_sleep|pose_run|pose_meow` for stills via `tools/screenshot.sh`).

## API / contract summary
- Nodes: `CatRig` → `Skeleton3D` → `CatBody` (1 surface, `CatFur`), `CatEyes` (surface 0 iris, 1 cornea),
  `CatWhiskers` (alpha clip). Faces +Z in Godot, origin on the ground between the paws, real scale.
- Fur: mask R = 1 ↔ 0.016 m (`cat_anatomy.FUR_MAX_LENGTH`); flow map decodes like a normal map's XY.
- See `docs/requests/cat-asset.md` for hand-off notes to `player`.

## Known gaps (honest)
- Topology is QuadriFlow-generated (quad-dominant, uniform-ish flow with density warps), not hand
  edge-looped; deformation is good in tests but the shoulders/armpits in extreme reaches (scratch,
  climb) stretch the fur texture a little.
- No claws mesh (optional in the contract); claws are implied by toe poses in scratch/climb/swipe.
- Hair-level realism in-engine depends on the player's shell fur; the base mesh alone reads as a
  short-haired, slightly smooth cat. The Cycles hero uses ~1.5 M generated strands (preview only).
- Eyelid blink is bone-driven; the third eyelid is not modelled. Pupil size is baked (mid slit);
  dilation would need a custom eye shader.
- The tail is an 8-bone chain; very tight curls (sleeping donut) are approximated.
- Turning/climb/scratch clips assume the controller conventions listed above.
- Hero gallery shot (1 M strands, 48 samples, 1280×800) crops the ear tips at the top edge and the
  closed mouth still reads as a slight dark slit (painted lip line + lip shading); a re-frame needs
  `target`/camera tweaks in `render_hero.py` and ~10 min of Cycles CPU.
- The assets/models/cat/cat_cat_*.{jpg,png} files next to the GLB are Godot's extracted embedded
  textures (import side effect), not separate sources.

## Tripo3D reference generation (`tools/tripo/tripo_cat.py`)
> Note: `tools/tripo/tripo_cat.py` is not in the repository yet; the commands below need it.

Calls the Tripo3D v3 API (text-to-model / image-to-model, H3.1 `v3.1-20260211`, PBR, detailed) to
produce a stylised "AAA + funny" cat as a *design reference* in `qa/out/tripo/<tag>/model.glb`.
```bash
export TRIPO_API_KEY=tsk_...                                   # https://platform.tripo3d.ai → API keys
py -3 tools/tripo/tripo_cat.py --seed 7                       # text prompt (default: cheeky orange tabby)
py -3 tools/tripo/tripo_cat.py --image docs/gallery/cat-asset_hero.jpg   # keep Cam's look, restyle
py -3 tools/tripo/tripo_cat.py --dry-run                      # inspect payload, no credits
```
The Tripo mesh is NOT a drop-in for `cat.glb`: it has no contract rig/clips. Use it as the sculpt
reference (shape proportions, face) and feed changes back into `cat_anatomy.py` / `cat_sdf.py`.

## VN orange tabby pass (`tools/rebuild_cat_vn.py`, PR #1 + review fixes)
Standalone NumPy/Pillow script that re-sculpts the head/muzzle directly in `cat.glb` and regenerates
all cat textures from `blender/lib/cat_coat.py` / `cat_tex.py`.
```bash
python3 tools/rebuild_cat_vn.py              # sculpt + textures (needs the ORIGINAL-geometry cache)
python3 tools/rebuild_cat_vn.py --tex-only   # textures only, from the GLB's current geometry/AO/normal
python3 tools/rebuild_cat_vn.py --geom-only  # sculpt only
```
- The full run reads the pre-sculpt geometry from `qa/out/cat-asset/cache/orig_glb_geom.npz`
  (git-ignored). If that cache is missing it is created from the *current* GLB, which would apply the
  sculpt a second time — use `--tex-only` on an already-sculpted GLB.
- Review fixes: whisker strands now move rigidly with the skin under their root (per-vertex
  displacement kinked the brow whiskers); coat agouti/`coat_var` contrast lowered (it read as
  camouflage blotches); forehead "M" strokes widened; cream eye-ring weight halved.
- Known gap: the edited GLB geometry no longer matches `blender/cat/cat.blend`; the eye-socket rim is
  still visibly faceted in close-ups (needs a Blender-side fix and re-export).
