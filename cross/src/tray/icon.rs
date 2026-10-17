//! The tray icon: our own eye monogram, drawn in code as ARGB32 pixmaps (no
//! icon theme, no image files). Open eye: holding awake. Closed eye: idle.
//! Open eye with a small laptop: a lid-closed session.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconKind {
    Idle,
    Awake,
    Lid,
}

/// Sizes we ship (the panel picks the closest).
pub const SIZES: [u32; 2] = [22, 44];

/// Supersampling factor per axis.
const SS: u32 = 4;

/// Light glyph with a dark rim, so it reads on dark and light panels.
const FG: [u8; 3] = [0xF4, 0xF4, 0xF4];
const RIM: [u8; 3] = [0x1E, 0x1E, 0x1E];
const RIM_ALPHA: f64 = 0.9;

/// Half the lens height at x (unit coords, eye centred at cx, cy).
fn lens(x: f64, cx: f64, w: f64, a: f64) -> Option<f64> {
    let u = (x - cx) / w;
    (u.abs() <= 1.0).then_some(a * (1.0 - u * u))
}

/// Distance from (px, py) to segment a-b.
fn seg_dist(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 { (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0) } else { 0.0 };
    let (qx, qy) = (ax + t * dx - px, ay + t * dy - py);
    (qx * qx + qy * qy).sqrt()
}

/// Whether unit point (x, y) is on the glyph.
fn inside(kind: IconKind, x: f64, y: f64) -> bool {
    let stroke = 0.085;
    let (cx, cy, w, a) = match kind {
        IconKind::Lid => (0.42, 0.36, 0.38, 0.23),
        _ => (0.5, 0.5, 0.46, 0.28),
    };
    let eye = match kind {
        IconKind::Idle => {
            // A closed lid: a downward curve, and three lashes below it.
            let curve = |x: f64| lens(x, cx, w, 0.22).map(|h| cy - 0.08 + h);
            let on_arc = curve(x).is_some_and(|c| (y - c).abs() <= stroke / 2.0);
            let lashes = [-0.5, 0.0, 0.5].iter().any(|u| {
                let bx = cx + u * w;
                let by = curve(bx).unwrap_or(cy);
                seg_dist(x, y, bx, by, bx + u * 0.10, by + 0.15) <= stroke / 2.0
            });
            on_arc || lashes
        }
        _ => {
            let ring = lens(x, cx, w, a).is_some_and(|h| {
                let d = (y - cy).abs();
                d <= h && d > h - stroke
            });
            let (dx, dy) = (x - cx, y - cy);
            let dist = (dx * dx + dy * dy).sqrt();
            let iris_r = a * 0.62;
            ring || (dist <= iris_r && dist >= iris_r * 0.36)
        }
    };
    if kind != IconKind::Lid {
        return eye;
    }
    // A small laptop, bottom right: a screen outline over a base bar.
    let (sx0, sy0, sx1, sy1) = (0.58, 0.63, 0.92, 0.85);
    let t = 0.07;
    let in_screen = x >= sx0 && x <= sx1 && y >= sy0 && y <= sy1;
    let screen_frame = in_screen && (x <= sx0 + t || x >= sx1 - t || y <= sy0 + t || y >= sy1 - t);
    let base = x >= sx0 - 0.05 && x <= sx1 + 0.05 && y >= sy1 + 0.03 && y <= sy1 + 0.10;
    eye || screen_frame || base
}

/// ARGB32, network byte order (what StatusNotifierItem expects), `size`×`size`.
pub fn render(kind: IconKind, size: u32) -> Vec<u8> {
    let size = size.clamp(8, 256);
    let n = size * SS;
    let idx = |x: u32, y: u32| (y * n + x) as usize;
    let mut mask = vec![false; (n * n) as usize];
    for y in 0..n {
        for x in 0..n {
            let (ux, uy) = ((f64::from(x) + 0.5) / f64::from(n), (f64::from(y) + 0.5) / f64::from(n));
            if let Some(m) = mask.get_mut(idx(x, y)) {
                *m = inside(kind, ux, uy);
            }
        }
    }
    // The rim: the glyph grown by about one output pixel.
    let grow = SS as i64;
    let rim_at = |x: u32, y: u32| -> bool {
        let (x, y) = (i64::from(x), i64::from(y));
        (-grow..=grow).any(|dy| {
            (-grow..=grow).any(|dx| {
                let (qx, qy) = (x + dx, y + dy);
                qx >= 0
                    && qy >= 0
                    && qx < i64::from(n)
                    && qy < i64::from(n)
                    && dx * dx + dy * dy <= grow * grow
                    && mask.get((qy * i64::from(n) + qx) as usize).copied().unwrap_or(false)
            })
        })
    };
    let mut out = Vec::with_capacity((size * size * 4) as usize);
    for oy in 0..size {
        for ox in 0..size {
            let (mut fg, mut rim) = (0u32, 0u32);
            for sy in 0..SS {
                for sx in 0..SS {
                    let (x, y) = (ox * SS + sx, oy * SS + sy);
                    if mask.get(idx(x, y)).copied().unwrap_or(false) {
                        fg += 1;
                    } else if rim_at(x, y) {
                        rim += 1;
                    }
                }
            }
            let total = f64::from(SS * SS);
            let (fa, ra) = (f64::from(fg) / total, f64::from(rim) / total * RIM_ALPHA);
            let alpha = (fa + ra).min(1.0);
            let mix = |i: usize| -> u8 {
                if alpha <= 0.0 {
                    return 0;
                }
                let f = f64::from(FG.get(i).copied().unwrap_or(0));
                let r = f64::from(RIM.get(i).copied().unwrap_or(0));
                // Within 0..=255 by construction; the cast saturates anyway.
                ((f * fa + r * ra) / alpha).round() as u8
            };
            out.push((alpha * 255.0).round() as u8);
            out.extend([mix(0), mix(1), mix(2)]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alpha(data: &[u8], size: u32, x: u32, y: u32) -> u8 {
        data[((y * size + x) * 4) as usize]
    }

    #[test]
    fn renders_every_kind_at_every_size() {
        for kind in [IconKind::Idle, IconKind::Awake, IconKind::Lid] {
            for size in SIZES {
                let d = render(kind, size);
                assert_eq!(d.len(), (size * size * 4) as usize);
                assert_eq!(alpha(&d, size, 0, 0), 0, "corners are clear");
                let ink = d.chunks(4).filter(|p| p[0] > 128).count();
                assert!(ink > (size * size / 20) as usize, "{kind:?} {size}: visible");
            }
        }
        let (idle, awake, lid) = (render(IconKind::Idle, 22), render(IconKind::Awake, 22), render(IconKind::Lid, 22));
        assert_ne!(idle, awake);
        assert_ne!(awake, lid);
        // The open eye has an iris; the closed one doesn't.
        assert!(alpha(&awake, 22, 13, 11) > 200 || alpha(&awake, 22, 8, 11) > 200);
        // The lid icon has its laptop in the bottom right.
        assert!(alpha(&lid, 22, 13, 15) > 128);
        assert_eq!(alpha(&awake, 22, 18, 19), 0);
        assert_eq!(render(IconKind::Idle, 0).len(), 8 * 8 * 4, "sizes are clamped");
    }

    /// `KW_ICON_DUMP=/dir cargo test dump_icons` writes raw RGBA files to look at.
    #[test]
    fn dump_icons() {
        let Some(dir) = std::env::var_os("KW_ICON_DUMP") else {
            return;
        };
        for (kind, name) in [(IconKind::Idle, "idle"), (IconKind::Awake, "awake"), (IconKind::Lid, "lid")] {
            for size in SIZES {
                let argb = render(kind, size);
                let rgba: Vec<u8> = argb.chunks(4).flat_map(|p| [p[1], p[2], p[3], p[0]]).collect();
                std::fs::write(std::path::Path::new(&dir).join(format!("{name}-{size}.rgba")), rgba).unwrap();
            }
        }
    }
}
