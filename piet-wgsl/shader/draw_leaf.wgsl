// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Also licensed under MIT license, at your choice.

// Finish prefix sum of drawtags, decode draw objects.

#import config
#import drawtag
#import bbox

@group(0) @binding(0)
var<storage> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> reduced: array<DrawMonoid>;

@group(0) @binding(3)
var<storage> path_bbox: array<PathBbox>;

@group(0) @binding(4)
var<storage, read_write> draw_monoid: array<DrawMonoid>;

@group(0) @binding(5)
var<storage, read_write> info: array<u32>;

let WG_SIZE = 256u;

// Possibly dedup?
struct Transform {
    matrx: vec4<f32>,
    translate: vec2<f32>,
}

fn read_transform(transform_base: u32, ix: u32) -> Transform {
    let base = transform_base + ix * 6u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base] + 1u);
    let c2 = bitcast<f32>(scene[base] + 2u);
    let c3 = bitcast<f32>(scene[base] + 3u);
    let c4 = bitcast<f32>(scene[base] + 4u);
    let c5 = bitcast<f32>(scene[base] + 5u);
    let matrx = vec4<f32>(c0, c1, c2, c3);
    let translate = vec2<f32>(c4, c5);
    return Transform(matrx, translate);
}

var<workgroup> sh_scratch: array<DrawMonoid, WG_SIZE>;

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    let ix = global_id.x;
    let tag_word = scene[config.drawtag_base + ix];
    var agg = map_draw_tag(tag_word);
    sh_scratch[local_id.x] = agg;
    for (var i = 0u; i < firstTrailingBit(WG_SIZE); i += 1u) {
        workgroupBarrier();
        if local_id.x + (1u << i) < WG_SIZE {
            let other = sh_scratch[local_id.x + (1u << i)];
            agg = combine_draw_monoid(agg, other);
        }
        workgroupBarrier();
        sh_scratch[local_id.x] = agg;
    }
    workgroupBarrier();
    var m = draw_monoid_identity();
    if wg_id.x > 0u {
        // TODO: separate dispatch to scan these, or integrate into this one?
        // In the meantime, will be limited to 2 * WG draw objs.
        m = reduced[wg_id.x - 1u];
    }
    if local_id.x > 0u {
        m = combine_draw_monoid(m, sh_scratch[local_id.x - 1u]);
    }
    // m now contains exclusive prefix sum of draw monoid
    draw_monoid[ix] = m;
    let dd = config.drawdata_base + m.scene_offset;
    let di = m.info_offset;
    if tag_word == DRAWTAG_FILL_COLOR || tag_word == DRAWTAG_FILL_LIN_GRADIENT ||
        tag_word == DRAWTAG_FILL_RAD_GRADIENT || tag_word == DRAWTAG_FILL_IMAGE ||
        tag_word == DRAWTAG_BEGIN_CLIP
    {
        let bbox = path_bbox[m.path_ix];
        // TODO: bbox is mostly yagni here, sort that out. Maybe clips?
        // let x0 = f32(bbox.x0);
        // let y0 = f32(bbox.y0);
        // let x1 = f32(bbox.x1);
        // let y1 = f32(bbox.y1);
        // let bbox_f = vec4(x0, y0, x1, y1);
        let fill_mode = u32(bbox.linewidth >= 0.0);
        var matrx: vec4<f32>;
        var translate: vec2<f32>;
        var linewidth = bbox.linewidth;
        if linewidth >= 0.0 || tag_word == DRAWTAG_FILL_LIN_GRADIENT || tag_word == DRAWTAG_FILL_RAD_GRADIENT {
            let transform = read_transform(config.transform_base, bbox.trans_ix);
            matrx = transform.matrx;
            translate = transform.translate;
        }
        if linewidth >= 0.0 {
            // Note: doesn't deal with anisotropic case
            linewidth *= sqrt(abs(matrx.x * matrx.w - matrx.y * matrx.z)); 
        }
        switch tag_word {
            // DRAWTAG_FILL_COLOR, DRAWTAG_FILL_IMAGE
            case 0x44u, 0x48u: {
                info[di] = bitcast<u32>(linewidth);
            }
            // DRAWTAG_FILL_LIN_GRADIENT
            case 0x114u: {
                info[di] = bitcast<u32>(linewidth);
                var p0 = bitcast<vec2<f32>>(vec2(scene[dd + 1u], scene[dd + 2u]));
                var p1 = bitcast<vec2<f32>>(vec2(scene[dd + 3u], scene[dd + 4u]));
                p0 = matrx.xy * p0.x + matrx.zw * p0.y + translate;
                p1 = matrx.xy * p1.x + matrx.zw * p1.y + translate;
                let dxy = p1 - p0;
                let scale = 1.0 / dot(dxy, dxy);
                let line_xy = dxy * scale;
                let line_c = -dot(p0, line_xy);
                info[di + 1u] = bitcast<u32>(line_xy.x);
                info[di + 2u] = bitcast<u32>(line_xy.y);
                info[di + 3u] = bitcast<u32>(line_c);
            }
            // DRAWTAG_FILL_RAD_GRADIENT
            case 0x2dcu: {
                info[di] = bitcast<u32>(linewidth);
                var p0 = bitcast<vec2<f32>>(vec2(scene[dd + 1u], scene[dd + 2u]));
                var p1 = bitcast<vec2<f32>>(vec2(scene[dd + 3u], scene[dd + 4u]));
                let r0 = bitcast<f32>(scene[dd + 5u]);
                let r1 = bitcast<f32>(scene[dd + 6u]);
                let inv_det = 1.0 / (matrx.x * matrx.w - matrx.y * matrx.z);
                let inv_mat = inv_det * vec4<f32>(matrx.w, -matrx.y, -matrx.z, matrx.x);
                var inv_tr = inv_mat.xz * translate.x + inv_mat.yw * translate.y;
                inv_tr += p0;
                let center1 = p1 - p0;
                let rr = r1 / (r1 - r0);
                let ra_inv = rr / (r1 * r1 - dot(center1, center1));
                let c1 = center1 * ra_inv;
                let ra = rr * ra_inv;
                let roff = rr - 1.0;
                info[di + 1u] = bitcast<u32>(inv_mat.x);
                info[di + 2u] = bitcast<u32>(inv_mat.y);
                info[di + 3u] = bitcast<u32>(inv_mat.z);
                info[di + 4u] = bitcast<u32>(inv_mat.w);
                info[di + 5u] = bitcast<u32>(inv_tr.x);
                info[di + 6u] = bitcast<u32>(inv_tr.y);
                info[di + 7u] = bitcast<u32>(c1.x);
                info[di + 8u] = bitcast<u32>(c1.y);
                info[di + 9u] = bitcast<u32>(ra);
                info[di + 10u] = bitcast<u32>(roff);
            }
            default: {}
        }
    }
}