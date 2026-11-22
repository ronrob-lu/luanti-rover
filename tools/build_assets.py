#!/usr/bin/env python3
"""
Build Luanti-ready skinned & tire-animated glTF (.glb) assets, textures,
and 64x64 inventory icons for both Moon Rovers:

  1. Drivable Moon Rover (Quaternius CC0, assets/Rover_1.gltf):
     - textures/moon_rover_atlas.png
     - models/moon_rover.glb          (5-joint skin + continuous tire animation)
     - textures/moon_rover_inv.png

  2. Autonomous Moon Rover (Kenney.nl CC0, assets/rover.glb):
     - textures/moon_rover_auto_atlas.png
     - models/moon_rover_auto.glb     (re-centered, +Z front, 5-joint skin + tire animation)
     - textures/moon_rover_auto_inv.png

Continuous glTF Animation Timeline (seconds, LINEAR interpolation):
  - 0.00 .. 1.00 : Full +360 deg forward tire rotation around +X
  - 1.20 .. 2.20 : Full -360 deg reverse tire rotation around +X

Code license: MIT (c) 2026 ronrob-lu
Asset licenses: CC0 1.0 Universal (Quaternius & Kenney.nl)
"""

import argparse
import base64
import json
import math
import struct
from pathlib import Path
from PIL import Image, ImageDraw


QUATERNIUS_SCALE = 6.0  # 10 mesh units = 1 node -> ~2.75w x 3.10l x 1.85 cabin height
KENNEY_SCALE = 40.0     # 10 mesh units = 1 node -> ~1.20w x 1.40l x 1.54 total height


def pad4(data: bytes, pad_byte: bytes = b"\x00") -> bytes:
    rem = len(data) % 4
    if rem:
        data += pad_byte * (4 - rem)
    return data


def read_gltf_accessor(gltf, raw_buf, acc_idx):
    acc = gltf["accessors"][acc_idx]
    bv = gltf["bufferViews"][acc["bufferView"]]
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    ctype = acc["componentType"]
    fmt_char = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}[ctype]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[acc["type"]]
    stride = bv.get("byteStride", struct.calcsize(fmt_char) * ncomp)
    fmt = "<" + (fmt_char * ncomp)
    out = []
    for i in range(acc["count"]):
        vals = struct.unpack_from(fmt, raw_buf, offset + i * stride)
        out.append(vals[0] if ncomp == 1 else vals)
    return out


def parse_glb(path: Path):
    data = path.read_bytes()
    magic, ver, total_len = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or ver != 2 or total_len != len(data):
        raise ValueError(f"Invalid GLB header in {path}")
    jlen, jtype = struct.unpack_from("<II", data, 12)
    assert jtype == 0x4E4F534A
    gltf = json.loads(data[20 : 20 + jlen].decode("utf-8"))
    blen, btype = struct.unpack_from("<II", data, 20 + jlen)
    assert btype == 0x004E4942
    bin_buf = data[20 + jlen + 8 : 20 + jlen + 8 + blen]
    return gltf, bin_buf


def normalize3(v):
    length = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) or 1.0
    return (v[0] / length, v[1] / length, v[2] / length)


def build_skinned_wheel_glb(
    out_glb: Path,
    generator: str,
    positions,
    normals,
    uvs,
    joint_indices,
    indices,
    wheel_axles,  # list of 4 (x, y, z) tuples for joints 1..4
):
    """
    Build a spec-compliant Luanti-ready skinned GLB with:
      - 1 mesh, 1 primitive, 1 material, 1 texture slot (no embedded images)
      - 5 joints: joint 0 = Body at (0,0,0), joints 1..4 = Wheel_1..Wheel_4 at wheel_axles
      - 1 continuous animation track:
          0.00..1.00 s: forward +360 deg around +X
          1.20..2.20 s: reverse -360 deg around +X
    """
    nverts = len(positions)
    if nverts >= 65535:
        raise ValueError(f"Vertex count {nverts} exceeds UNSIGNED_SHORT limit")
    assert len(normals) == nverts and len(uvs) == nverts and len(joint_indices) == nverts
    assert len(wheel_axles) == 4

    pos_min = [min(p[i] for p in positions) for i in range(3)]
    pos_max = [max(p[i] for p in positions) for i in range(3)]

    # Pack vertex attributes (each 4-byte aligned)
    pos_bytes = bytearray()
    for x, y, z in positions:
        pos_bytes += struct.pack("<fff", x, y, z)

    nrm_bytes = bytearray()
    for x, y, z in normals:
        nx, ny, nz = normalize3((x, y, z))
        nrm_bytes += struct.pack("<fff", nx, ny, nz)

    uv_bytes = bytearray()
    for u, v in uvs:
        uv_bytes += struct.pack("<ff", u, v)

    jnt_bytes = bytearray()
    for j in joint_indices:
        jnt_bytes += struct.pack("<BBBB", j, 0, 0, 0)

    wgt_bytes = bytearray()
    for _ in range(nverts):
        wgt_bytes += struct.pack("<ffff", 1.0, 0.0, 0.0, 0.0)

    idx_bytes = bytearray()
    for idx in indices:
        idx_bytes += struct.pack("<H", idx)
    idx_bytes_padded = pad4(bytes(idx_bytes), b"\x00")

    # Inverse bind matrices (5 x MAT4, column-major):
    # Joint 0 (Body): Identity
    # Joint 1..4 (Wheels): Translate(-ax, -ay, -az)
    ibm_bytes = bytearray()
    joint_translations = [(0.0, 0.0, 0.0)] + list(wheel_axles)
    for tx, ty, tz in joint_translations:
        # Column-major 4x4 translation matrix for (-tx, -ty, -tz)
        mat = (
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            -tx, -ty, -tz, 1.0,
        )
        ibm_bytes += struct.pack("<16f", *mat)

    # Continuous animation timeline (10 keyframes):
    # Luanti's glTF loader negates Z (glTF -Z -> Luanti +Z forward).
    # Therefore:
    #   0.00..1.00 : forward spin (-360 deg around +X in glTF -> top moves glTF -Z = Luanti +Z)
    #   1.20..2.20 : reverse spin (+360 deg around +X in glTF -> top moves glTF +Z = Luanti -Z)
    s = math.sqrt(0.5)
    anim_times = [0.00, 0.25, 0.50, 0.75, 1.00, 1.20, 1.45, 1.70, 1.95, 2.20]
    anim_quats = [
        (0.0, 0.0, 0.0, 1.0),
        (-s,  0.0, 0.0, s),
        (-1.0, 0.0, 0.0, 0.0),
        (-s,  0.0, 0.0, -s),
        (0.0, 0.0, 0.0, -1.0),
        (0.0, 0.0, 0.0, 1.0),
        (s,   0.0, 0.0, s),
        (1.0, 0.0, 0.0, 0.0),
        (s,   0.0, 0.0, -s),
        (0.0, 0.0, 0.0, -1.0),
    ]

    time_bytes = bytearray()
    for t in anim_times:
        time_bytes += struct.pack("<f", t)

    quat_bytes = bytearray()
    for qx, qy, qz, qw in anim_quats:
        quat_bytes += struct.pack("<ffff", qx, qy, qz, qw)

    # Assemble binary buffer with exact byte offsets
    chunks = [
        ("pos", bytes(pos_bytes), len(pos_bytes), 34962),
        ("nrm", bytes(nrm_bytes), len(nrm_bytes), 34962),
        ("uv",  bytes(uv_bytes),  len(uv_bytes),  34962),
        ("jnt", bytes(jnt_bytes), len(jnt_bytes), 34962),
        ("wgt", bytes(wgt_bytes), len(wgt_bytes), 34962),
        ("idx", idx_bytes_padded, len(idx_bytes), 34963),
        ("ibm", bytes(ibm_bytes), len(ibm_bytes), None),
        ("tim", bytes(time_bytes), len(time_bytes), None),
        ("rot", bytes(quat_bytes), len(quat_bytes), None),
    ]

    bin_blob = bytearray()
    buffer_views = []
    for _, raw, logical_len, target in chunks:
        off = len(bin_blob)
        bin_blob += pad4(raw, b"\x00")
        bv = {"buffer": 0, "byteOffset": off, "byteLength": logical_len}
        if target is not None:
            bv["target"] = target
        buffer_views.append(bv)

    # Scene nodes:
    #   0: RoverMesh (mesh=0, skin=0, identity transform)
    #   1: Body      (root joint, children=[2,3,4,5])
    #   2..5: Wheel_1..Wheel_4 (child joints at exact axle translations)
    nodes = [
        {"name": "RoverMesh", "mesh": 0, "skin": 0},
        {"name": "Body", "children": [2, 3, 4, 5], "translation": [0.0, 0.0, 0.0]},
    ]
    for wi, (ax, ay, az) in enumerate(wheel_axles, start=1):
        nodes.append(
            {
                "name": f"Wheel_{wi}",
                "translation": [ax, ay, az],
                "rotation": [0.0, 0.0, 0.0, 1.0],
            }
        )

    channels = [
        {"sampler": 0, "target": {"node": 2 + i, "path": "rotation"}}
        for i in range(4)
    ]

    gltf_json = {
        "asset": {"version": "2.0", "generator": generator},
        "scene": 0,
        "scenes": [{"name": "Scene", "nodes": [0, 1]}],
        "nodes": nodes,
        "skins": [
            {
                "name": "RoverSkin",
                "inverseBindMatrices": 6,
                "skeleton": 1,
                "joints": [1, 2, 3, 4, 5],
            }
        ],
        "animations": [
            {
                "name": "wheels",
                "channels": channels,
                "samplers": [
                    {
                        "input": 7,
                        "interpolation": "LINEAR",
                        "output": 8,
                    }
                ],
            }
        ],
        "meshes": [
            {
                "name": "Rover",
                "primitives": [
                    {
                        "attributes": {
                            "POSITION": 0,
                            "NORMAL": 1,
                            "TEXCOORD_0": 2,
                            "JOINTS_0": 3,
                            "WEIGHTS_0": 4,
                        },
                        "indices": 5,
                        "material": 0,
                        "mode": 4,
                    }
                ],
            }
        ],
        "materials": [
            {
                "name": "Atlas",
                "doubleSided": True,
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.5,
                },
            }
        ],
        "textures": [{"sampler": 0}],
        "samplers": [
            {"magFilter": 9728, "minFilter": 9728, "wrapS": 10497, "wrapT": 10497}
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": nverts,
                "type": "VEC3",
                "min": pos_min,
                "max": pos_max,
            },
            {"bufferView": 1, "componentType": 5126, "count": nverts, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": nverts, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5121, "count": nverts, "type": "VEC4"},
            {"bufferView": 4, "componentType": 5126, "count": nverts, "type": "VEC4"},
            {
                "bufferView": 5,
                "componentType": 5123,
                "count": len(indices),
                "type": "SCALAR",
                "min": [0],
                "max": [nverts - 1],
            },
            {"bufferView": 6, "componentType": 5126, "count": 5, "type": "MAT4"},
            {
                "bufferView": 7,
                "componentType": 5126,
                "count": len(anim_times),
                "type": "SCALAR",
                "min": [min(anim_times)],
                "max": [max(anim_times)],
            },
            {
                "bufferView": 8,
                "componentType": 5126,
                "count": len(anim_quats),
                "type": "VEC4",
            },
        ],
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(bin_blob)}],
    }

    json_bytes = pad4(json.dumps(gltf_json, separators=(",", ":")).encode("utf-8"), b" ")
    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_blob)

    glb = bytearray()
    glb += struct.pack("<4sII", b"glTF", 2, total_len)
    glb += struct.pack("<II", len(json_bytes), 0x4E4F534A)
    glb += json_bytes
    glb += struct.pack("<II", len(bin_blob), 0x004E4942)
    glb += bin_blob

    out_glb.parent.mkdir(parents=True, exist_ok=True)
    out_glb.write_bytes(glb)
    return pos_min, pos_max, len(glb)


def render_inventory_icon(positions, uvs, indices, atlas_path: Path, out_inv: Path, yaw_deg=142, pitch_deg=24):
    atlas = Image.open(atlas_path).convert("RGBA")
    aw, ah = atlas.size

    ss = 256
    img = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cy = 0.5 * (min(p[1] for p in positions) + max(p[1] for p in positions))
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    cyaw, syaw = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    lx, ly, lz = 0.42, 0.78, 0.46

    def project(p):
        x, y, z = p[0], p[1] - cy, p[2]
        x1 = x * cyaw - z * syaw
        z1 = x * syaw + z * cyaw
        y2 = y * cp - z1 * sp
        z2 = y * sp + z1 * cp
        return x1, y2, z2

    proj_pts = [project(p) for p in positions]
    xs = [p[0] for p in proj_pts]
    ys = [p[1] for p in proj_pts]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    fit = (ss * 0.86) / span
    mx = 0.5 * (min(xs) + max(xs))
    my = 0.5 * (min(ys) + max(ys))

    tris = []
    for i in range(0, len(indices), 3):
        i0, i1, i2 = indices[i], indices[i + 1], indices[i + 2]
        p0, p1, p2 = proj_pts[i0], proj_pts[i1], proj_pts[i2]
        depth = (p0[2] + p1[2] + p2[2]) / 3.0

        u = ((uvs[i0][0] + uvs[i1][0] + uvs[i2][0]) / 3.0) % 1.0
        v = ((uvs[i0][1] + uvs[i1][1] + uvs[i2][1]) / 3.0) % 1.0
        px = min(aw - 1, max(0, int(u * aw)))
        py = min(ah - 1, max(0, int(v * ah)))
        r, g, b, a = atlas.getpixel((px, py))
        if a == 0:
            # Render transparent windows as sleek tinted glass on the 64x64 inventory icon
            r, g, b = 48, 72, 96

        a, b_v, c = positions[i0], positions[i1], positions[i2]
        ux, uy, uz = b_v[0] - a[0], b_v[1] - a[1], b_v[2] - a[2]
        vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        nx, ny, nz = normalize3((nx, ny, nz))

        ndotl = max(0.0, nx * lx + ny * ly + nz * lz)
        hemi = 0.45 + 0.15 * max(-1.0, min(1.0, ny))
        shade = min(1.12, hemi + 0.58 * ndotl)
        col = (min(255, int(r * shade)), min(255, int(g * shade)), min(255, int(b * shade)), 255)

        poly = [
            (ss * 0.5 + (p0[0] - mx) * fit, ss * 0.5 - (p0[1] - my) * fit),
            (ss * 0.5 + (p1[0] - mx) * fit, ss * 0.5 - (p1[1] - my) * fit),
            (ss * 0.5 + (p2[0] - mx) * fit, ss * 0.5 - (p2[1] - my) * fit),
        ]
        tris.append((depth, poly, col))

    tris.sort(key=lambda t: t[0])
    for _, poly, col in tris:
        draw.polygon(poly, fill=col)

    out_inv.parent.mkdir(parents=True, exist_ok=True)
    img.resize((64, 64), Image.LANCZOS).save(out_inv)


def build_quaternius_rover(src_gltf: Path, out_glb: Path, out_atlas: Path, out_inv: Path, scale: float):
    with src_gltf.open("r", encoding="utf-8") as f:
        gltf = json.load(f)

    buf_uri = gltf["buffers"][0]["uri"]
    raw_buf = base64.b64decode(buf_uri.split(",", 1)[1])

    # Extract Atlas PNG and make pixel (6, 0) (used exclusively by the 56 rover window
    # triangles) transparent (alpha = 0) so Luanti's alpha-clip material renders clear
    # cockpit windows with zero depth-sorting artifacts.
    img_info = gltf["images"][0]
    img_bv = gltf["bufferViews"][img_info["bufferView"]]
    img_off = img_bv.get("byteOffset", 0)
    img_bytes = raw_buf[img_off : img_off + img_bv["byteLength"]]
    out_atlas.parent.mkdir(parents=True, exist_ok=True)
    out_atlas.write_bytes(img_bytes)

    atlas_img = Image.open(out_atlas).convert("RGBA")
    atlas_img.putpixel((6, 0), (120, 180, 220, 0))
    atlas_img.save(out_atlas)

    # First pass: collect body + 4 wheel nodes and compute global min_y
    scene_nodes = gltf["scenes"][gltf.get("scene", 0)]["nodes"]
    parts = []
    min_y = float("inf")
    wheel_order = []

    for node_idx in scene_nodes:
        node = gltf["nodes"][node_idx]
        if "mesh" not in node:
            continue
        name = node.get("name", "")
        tx, ty, tz = node.get("translation", [0.0, 0.0, 0.0])
        sx, sy, sz = node.get("scale", [1.0, 1.0, 1.0])
        is_wheel = name.startswith("Wheel_")
        if is_wheel:
            joint_idx = 1 + len(wheel_order)
            wheel_order.append((tx, ty, tz))
        else:
            joint_idx = 0

        mesh = gltf["meshes"][node["mesh"]]
        for prim in mesh["primitives"]:
            positions = read_gltf_accessor(gltf, raw_buf, prim["attributes"]["POSITION"])
            normals = read_gltf_accessor(gltf, raw_buf, prim["attributes"]["NORMAL"])
            uvs = read_gltf_accessor(gltf, raw_buf, prim["attributes"]["TEXCOORD_0"])
            indices = read_gltf_accessor(gltf, raw_buf, prim["indices"])
            world_pos = [(p[0] * sx + tx, p[1] * sy + ty, p[2] * sz + tz) for p in positions]
            for p in world_pos:
                if p[1] < min_y:
                    min_y = p[1]
            parts.append((joint_idx, world_pos, normals, uvs, indices))

    assert len(wheel_order) == 4, f"Expected 4 wheels in Rover_1.gltf, got {len(wheel_order)}"

    # Second pass: ground min_y -> 0, scale, and rotate 180 deg around Y
    # so windshield faces glTF -Z (which Luanti's glTF loader maps to +Z forward).
    merged_pos, merged_nrm, merged_uv, merged_jnt, merged_idx = [], [], [], [], []
    for joint_idx, world_pos, normals, uvs, indices in parts:
        base = len(merged_pos)
        for p in world_pos:
            merged_pos.append((-p[0] * scale, (p[1] - min_y) * scale, -p[2] * scale))
        for n in normals:
            merged_nrm.append((-n[0], n[1], -n[2]))
        merged_uv.extend(uvs)
        merged_jnt.extend([joint_idx] * len(world_pos))
        merged_idx.extend(i + base for i in indices)

    wheel_axles = [(-tx * scale, (ty - min_y) * scale, -tz * scale) for (tx, ty, tz) in wheel_order]

    pos_min, pos_max, glb_size = build_skinned_wheel_glb(
        out_glb=out_glb,
        generator="moon_rover build_assets.py (Quaternius Rover_1 CC0, animated wheels)",
        positions=merged_pos,
        normals=merged_nrm,
        uvs=merged_uv,
        joint_indices=merged_jnt,
        indices=merged_idx,
        wheel_axles=wheel_axles,
    )
    render_inventory_icon(merged_pos, merged_uv, merged_idx, out_atlas, out_inv)

    print(f"[Drivable Rover] {out_glb.name}: {glb_size} bytes, {len(merged_pos)} verts, {len(merged_idx)//3} tris")
    print(f"  Nodes size (10u=1n): {[round((pos_max[i]-pos_min[i])/10.0, 2) for i in range(3)]}")


def build_kenney_rover(src_glb: Path, out_glb: Path, out_atlas: Path, out_inv: Path, scale: float):
    gltf, raw_buf = parse_glb(src_glb)

    # Bake Kenney's 4 baseColorFactor materials into a crisp 16x16 palette PNG
    # Materials in rover.glb: 0=dark, 1=metal, 2=metalRed (golden yellow-orange), 3=metalDark
    palette_colors = [
        (70, 76, 87, 255),     # 0: dark (tires, antenna, sensor eye)
        (218, 224, 234, 255),  # 1: metal (bright rover hull & hubcaps)
        (246, 178, 52, 255),   # 2: metalRed (warm yellow-orange front hood)
        (162, 172, 188, 255),  # 3: metalDark (chassis lower skirt)
    ]
    uv_centers = [
        (0.25, 0.25),  # top-left 8x8
        (0.75, 0.25),  # top-right 8x8
        (0.25, 0.75),  # bottom-left 8x8
        (0.75, 0.75),  # bottom-right 8x8
    ]
    atlas = Image.new("RGBA", (16, 16))
    for qi, col in enumerate(palette_colors):
        ox = (qi % 2) * 8
        oy = (qi // 2) * 8
        for py in range(oy, oy + 8):
            for px in range(ox, ox + 8):
                atlas.putpixel((px, py), col)
    out_atlas.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(out_atlas)

    # Read all primitives from mesh 0 (ignoring node[1]'s off-center [2, 0, 1.5] translation)
    mesh = gltf["meshes"][0]
    raw_tris = []
    min_y = float("inf")

    for prim in mesh["primitives"]:
        mat_idx = prim["material"]
        positions = read_gltf_accessor(gltf, raw_buf, prim["attributes"]["POSITION"])
        normals = read_gltf_accessor(gltf, raw_buf, prim["attributes"]["NORMAL"])
        indices = read_gltf_accessor(gltf, raw_buf, prim["indices"])

        for p in positions:
            if p[1] < min_y:
                min_y = p[1]

        for i in range(0, len(indices), 3):
            i0, i1, i2 = indices[i], indices[i + 1], indices[i + 2]
            pts = [positions[i0], positions[i1], positions[i2]]
            nrms = [normals[i0], normals[i1], normals[i2]]
            raw_tris.append((mat_idx, pts, nrms))

    # Classify triangles into Body (joint 0) vs 4 Wheels (joints 1..4).
    # In raw Kenney coords, the sloped yellow sensor nose ALREADY faces glTF -Z
    # (which Luanti's glTF loader maps directly to +Z forward!).
    quad_to_joint = {
        (1, -1): 1,
        (-1, 1): 2,
        (1, 1): 3,
        (-1, -1): 4,
    }
    wheel_bounds = {j: [[1e9, -1e9], [1e9, -1e9], [1e9, -1e9]] for j in range(1, 5)}

    merged_pos, merged_nrm, merged_uv, merged_jnt, merged_idx = [], [], [], [], []
    for mat_idx, pts, nrms in raw_tris:
        is_wheel = (
            all(abs(p[0]) >= 0.099 and p[1] <= 0.095 and abs(p[2]) <= 0.13 for p in pts)
            and any(abs(p[0]) > 0.105 for p in pts)
        )
        if is_wheel:
            sx = 1 if pts[0][0] > 0 else -1
            sz = 1 if sum(p[2] for p in pts) > 0 else -1
            jnt = quad_to_joint[(sx, sz)]
        else:
            jnt = 0

        uv = uv_centers[mat_idx]
        base = len(merged_pos)
        for p, n in zip(pts, nrms):
            gp = (p[0] * scale, (p[1] - min_y) * scale, p[2] * scale)
            gn = (n[0], n[1], n[2])
            merged_pos.append(gp)
            merged_nrm.append(gn)
            merged_uv.append(uv)
            merged_jnt.append(jnt)
            if jnt > 0:
                b = wheel_bounds[jnt]
                for axis in range(3):
                    b[axis][0] = min(b[axis][0], gp[axis])
                    b[axis][1] = max(b[axis][1], gp[axis])
        merged_idx.extend([base, base + 1, base + 2])

    wheel_axles = []
    for j in range(1, 5):
        b = wheel_bounds[j]
        wheel_axles.append(
            (
                0.5 * (b[0][0] + b[0][1]),
                0.5 * (b[1][0] + b[1][1]),
                0.5 * (b[2][0] + b[2][1]),
            )
        )

    pos_min, pos_max, glb_size = build_skinned_wheel_glb(
        out_glb=out_glb,
        generator="moon_rover build_assets.py (Kenney.nl Space Kit rover CC0, animated wheels)",
        positions=merged_pos,
        normals=merged_nrm,
        uvs=merged_uv,
        joint_indices=merged_jnt,
        indices=merged_idx,
        wheel_axles=wheel_axles,
    )
    render_inventory_icon(merged_pos, merged_uv, merged_idx, out_atlas, out_inv)

    print(f"[Autonomous Rover] {out_glb.name}: {glb_size} bytes, {len(merged_pos)} verts, {len(merged_idx)//3} tris")
    print(f"  Nodes size (10u=1n): {[round((pos_max[i]-pos_min[i])/10.0, 2) for i in range(3)]}")


def validate_skinned_glb(glb_path: Path):
    gltf, bin_buf = parse_glb(glb_path)
    assert "images" not in gltf, "Embedded images must be stripped for Luanti"
    assert len(gltf["textures"]) == 1 and "source" not in gltf["textures"][0]
    assert len(gltf["meshes"]) == 1 and len(gltf["meshes"][0]["primitives"]) == 1
    assert len(gltf["skins"]) == 1 and len(gltf["skins"][0]["joints"]) == 5
    assert len(gltf["animations"]) == 1 and len(gltf["animations"][0]["channels"]) == 4

    # Verify skinned mesh node has identity transform
    mesh_node = gltf["nodes"][0]
    for k in ("translation", "rotation", "scale", "matrix"):
        assert k not in mesh_node, f"Skinned mesh node must not have {k}"

    # Verify accessors & bufferView alignment
    for bv in gltf["bufferViews"]:
        assert bv["byteOffset"] % 4 == 0
        assert bv["byteOffset"] + bv["byteLength"] <= len(bin_buf)

    # Verify skinning equation at bind pose & 90-deg forward rotation (t = 0.25)
    positions = read_gltf_accessor(gltf, bin_buf, 0)
    joints = read_gltf_accessor(gltf, bin_buf, 3)
    weights = read_gltf_accessor(gltf, bin_buf, 4)
    ibms = read_gltf_accessor(gltf, bin_buf, 6)
    times = read_gltf_accessor(gltf, bin_buf, 7)
    quats = read_gltf_accessor(gltf, bin_buf, 8)
    assert times == sorted(times) and abs(times[0] - 0.0) < 1e-6 and abs(times[-1] - 2.2) < 1e-5

    # Verify weights sum to 1.0 and joint indices are in 0..4
    for jv, wv in zip(joints, weights):
        assert 0 <= jv[0] <= 4
        assert abs(sum(wv) - 1.0) < 1e-6

    # Check forward spin at t = 0.25 (-90 deg around +X in glTF -> top moves glTF -Z = Luanti +Z):
    w1_node = gltf["nodes"][2]
    ax, ay, az = w1_node["translation"]
    w1_verts = [p for p, jv in zip(positions, joints) if jv[0] == 1]
    top_v = max(w1_verts, key=lambda p: p[1])
    lx, ly, lz = top_v[0] - ax, top_v[1] - ay, top_v[2] - az
    qx, qy, qz, qw = quats[1]
    rx = lx
    ry = ly * (1 - 2 * qx * qx) - lz * (2 * qx * qw)
    rz = ly * (2 * qx * qw) + lz * (1 - 2 * qx * qx)
    assert rz < -ly * 0.9, f"Top of wheel should move glTF -Z (Luanti +Z forward) at t=0.25, got {(rx, ry, rz)}"
    assert abs(math.hypot(ry, rz) - math.hypot(ly, lz)) < 1e-4

    # Check reverse spin at t = 1.45 (+90 deg around +X in glTF -> top moves glTF +Z = Luanti -Z):
    qx, qy, qz, qw = quats[6]
    rz_rev = ly * (2 * qx * qw) + lz * (1 - 2 * qx * qx)
    assert rz_rev > ly * 0.9, f"Top of wheel should move glTF +Z (Luanti -Z reverse) at t=1.45, got {rz_rev}"
    print(f"  Validation PASSED for {glb_path.name} (front at glTF -Z -> Luanti +Z; wheels roll forward)")


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Build both Luanti Moon Rover models, textures, and icons")
    parser.add_argument("--quaternius-scale", type=float, default=QUATERNIUS_SCALE)
    parser.add_argument("--kenney-scale", type=float, default=KENNEY_SCALE)
    args = parser.parse_args()

    q_glb = root / "models" / "moon_rover.glb"
    build_quaternius_rover(
        src_gltf=root / "assets" / "Rover_1.gltf",
        out_glb=q_glb,
        out_atlas=root / "textures" / "moon_rover_atlas.png",
        out_inv=root / "textures" / "moon_rover_inv.png",
        scale=args.quaternius_scale,
    )
    validate_skinned_glb(q_glb)

    k_glb = root / "models" / "moon_rover_auto.glb"
    build_kenney_rover(
        src_glb=root / "assets" / "rover.glb",
        out_glb=k_glb,
        out_atlas=root / "textures" / "moon_rover_auto_atlas.png",
        out_inv=root / "textures" / "moon_rover_auto_inv.png",
        scale=args.kenney_scale,
    )
    validate_skinned_glb(k_glb)


if __name__ == "__main__":
    main()
