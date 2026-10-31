// Regenerates rough-golden.json, the reference output the Swift ports of
// rough.js and perfect-freehand are tested against.
//
//   npm install roughjs@4.6.6 perfect-freehand@1.2.3
//   node rough-golden.mjs > rough-golden.json
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const rough = require('roughjs/bundled/rough.cjs.js');
const { getStroke } = require('perfect-freehand');

const g = rough.generator();
const r6 = (v) => Math.round(v * 1e6) / 1e6;
const flat = (d) => d.sets.map((s) => ({ type: s.type, ops: s.ops.map((o) => [o.op, ...o.data.map(r6)]) }));
const easing = (t) => Math.sin((t * Math.PI) / 2);
const out = {};

out.line = flat(g.line(10, 20, 200, 80, { seed: 42 }));
out.rectangle = flat(g.rectangle(0, 0, 120, 80, { seed: 7, preserveVertices: true, roughness: 1, fillWeight: 1, hachureGap: 8, strokeWidth: 2 }));
out.ellipse = flat(g.ellipse(50, 40, 100, 80, { seed: 99, curveFitting: 1, roughness: 1, strokeWidth: 2 }));
out.ellipseFillSolid = flat(g.ellipse(50, 40, 100, 80, { seed: 99, curveFitting: 1, roughness: 1, strokeWidth: 2, fill: '#f00', fillStyle: 'solid' }));
out.rectHachure = flat(g.rectangle(0, 0, 100, 60, { seed: 3, preserveVertices: true, roughness: 1, fill: '#0f0', fillStyle: 'hachure', fillWeight: 1, hachureGap: 8, strokeWidth: 2 }));
out.curve = flat(g.curve([[0, 0], [50, 30], [100, 0], [150, 40]], { seed: 11, roughness: 1, strokeWidth: 2, preserveVertices: true }));
out.linearPath = flat(g.linearPath([[0, 0], [60, 20], [120, -10]], { seed: 5, roughness: 1, strokeWidth: 2, preserveVertices: true }));
out.polygon = flat(g.polygon([[51, 0], [100, 41], [51, 80], [0, 41]], { seed: 8, roughness: 1, strokeWidth: 2, fill: '#00f', fillStyle: 'cross-hatch', fillWeight: 1, hachureGap: 8 }));
out.path = flat(g.path('M 32 0 L 168 0 Q 200 0, 200 32 L 200 88 Q 200 120, 168 120 L 32 120 Q 0 120, 0 88 L 0 32 Q 0 0, 32 0', { seed: 21, roughness: 1, strokeWidth: 2, preserveVertices: true, fill: '#ff0', fillStyle: 'solid' }));
out.architect = flat(g.rectangle(0, 0, 80, 40, { seed: 2, roughness: 0, strokeWidth: 2, preserveVertices: true }));
out.ellipseArchitect = flat(g.ellipse(20, 20, 40, 40, { seed: 2, roughness: 0, curveFitting: 1, strokeWidth: 2 }));
out.zigzag = flat(g.rectangle(0, 0, 60, 40, { seed: 13, preserveVertices: true, roughness: 1, fill: '#0f0', fillStyle: 'zigzag', fillWeight: 1, hachureGap: 8, strokeWidth: 2 }));
out.dashedRect = flat(g.rectangle(0, 0, 90, 50, { seed: 17, preserveVertices: true, roughness: 1, strokeWidth: 2.5, disableMultiStroke: true }));

const pts = [[0, 0], [5, 2], [12, 6], [20, 12], [30, 15], [42, 14], [55, 10], [66, 4], [75, 0], [80, -3]];
const stroke = (points, size, simulatePressure) =>
  getStroke(points, { simulatePressure, size, thinning: 0.6, smoothing: 0.5, streamline: 0.5, easing, last: true }).map((p) => p.map(r6));
out.freehand = stroke(pts, 2 * 4.25, true);
out.freehandPressure = stroke(pts.map((p, i) => [p[0], p[1], 0.2 + i * 0.07]), 4 * 4.25, false);
out.freehandDot = stroke([[3, 4]], 8.5, true);

process.stdout.write(JSON.stringify(out));
