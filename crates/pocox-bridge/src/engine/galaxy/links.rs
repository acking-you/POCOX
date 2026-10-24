//! Links: how each one's data travels, and the strands drawn for it.

use super::{count, Camera, Frame, Out, Scene, V3};

/// How a link's data travels, as the app observed it. Each drawn strand
/// carries one too: a mixed link draws a direct and a relay strand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LinkPath {
    /// Not observed: drawn as links were before paths were known.
    Unknown,
    /// Through the relay, by preference or after a fallback.
    Relay,
    /// Peer to peer.
    Direct,
    /// Direct and relay connections at once.
    Mixed,
    /// Ready, with no data flowing.
    Idle,
    /// Trying a direct path: hole punching is under way.
    Probing,
    /// Coming up, or recovering its link to the relay.
    Recovering,
}

impl LinkPath {
    /// The scene's code: 0 unknown, 1 relay, 2 direct, 3 mixed, 4 idle,
    /// 5 probing, 6 recovering.
    pub(super) fn decode(code: f64) -> Option<Self> {
        Some(match count(code, 6)? {
            0 => Self::Unknown,
            1 => Self::Relay,
            2 => Self::Direct,
            3 => Self::Mixed,
            4 => Self::Idle,
            5 => Self::Probing,
            _ => Self::Recovering,
        })
    }

    fn code(self) -> f64 {
        match self {
            Self::Unknown => 0.0,
            Self::Relay => 1.0,
            Self::Direct => 2.0,
            Self::Mixed => 3.0,
            Self::Idle => 4.0,
            Self::Probing => 5.0,
            Self::Recovering => 6.0,
        }
    }

    /// The strands drawn for it.
    fn strands(self) -> &'static [Self] {
        match self {
            Self::Mixed => &[Self::Direct, Self::Relay],
            Self::Unknown => &[Self::Unknown],
            Self::Relay => &[Self::Relay],
            Self::Direct => &[Self::Direct],
            Self::Idle => &[Self::Idle],
            Self::Probing => &[Self::Probing],
            Self::Recovering => &[Self::Recovering],
        }
    }

    /// How high a strand spanning `span` rises over the plane: a direct one
    /// (or one trying to be) runs nearly straight between the two bodies;
    /// any other arcs up and back down, as if by way of a relay above the
    /// disk.
    fn rise(self, span: f64) -> f64 {
        match self {
            Self::Direct | Self::Probing => span * 0.12 + 0.12,
            _ => span * 0.42 + 0.4,
        }
    }

    /// How fast its particles run, in curves per second: quick while probing,
    /// none while idle or recovering.
    fn flow(self) -> Option<f64> {
        match self {
            Self::Direct => Some(0.42),
            Self::Probing => Some(0.9),
            Self::Idle | Self::Recovering => None,
            _ => Some(0.22),
        }
    }
}

/// One link: the body it reaches, the system using it, and its path.
#[derive(Clone, Copy, Debug)]
pub(super) struct Link {
    /// A body index: systems first, then planets. A device's star when the
    /// connection reaches no service of it that the galaxy shows.
    pub(super) target: usize,
    pub(super) system: usize,
    pub(super) path: LinkPath,
}

pub(super) fn draw(scene: &Scene, frame: &Frame, camera: &Camera, out: &mut Out) {
    let count = out.hole();
    let mut n = 0;
    for link in &scene.links {
        let from = match link.target.checked_sub(scene.systems.len()) {
            None => scene.systems[link.target].position,
            Some(planet) => {
                let p = &scene.planets[planet];
                scene.systems[p.system]
                    .position
                    .add(p.offset_at(frame.orbit_time()))
            },
        };
        let to = scene.systems[link.system].position;
        let (span, middle) = (to.sub(from).length(), from.lerp(to, 0.5));
        for &strand in link.path.strands() {
            let control = middle.add(V3::new(0.0, strand.rise(span), 0.0));
            let at = |t: f64| {
                from.mul((1.0 - t) * (1.0 - t))
                    .add(control.mul(2.0 * (1.0 - t) * t))
                    .add(to.mul(t * t))
            };
            let mut points = [(0.0, 0.0); 33];
            let mut len = 0;
            for i in 0..=32 {
                if let Some(p) = camera.at(at(i as f64 / 32.0)) {
                    points[len] = (p.x, p.y);
                    len += 1;
                }
            }
            if len < 2 {
                continue;
            }
            out.push(strand.code());
            out.points(&points[..len]);
            let mut particles = [(0.0, 0.0); 3];
            let mut len = 0;
            if let Some(flow) = strand.flow() {
                for k in 0..3 {
                    let t = if frame.still {
                        (k + 1) as f64 / 4.0
                    } else {
                        (frame.time * flow + k as f64 / 3.0).rem_euclid(1.0)
                    };
                    if let Some(p) = camera.at(at(t)) {
                        particles[len] = (p.x, p.y);
                        len += 1;
                    }
                }
            }
            out.points(&particles[..len]);
            n += 1;
        }
    }
    out.fill(count, n as f64);
}
