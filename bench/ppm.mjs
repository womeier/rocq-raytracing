// PPM in, PNG out -- and the comparison between two renders of one example.
//
//   node bench/ppm.mjs png  a.ppm a.png
//   node bench/ppm.mjs diff rocq.ppm lean.ppm [diff.png]
//
// The Rocq module writes P6 (binary), the Lean programs write P3 (ASCII);
// both are read here.  `diff` prints one JSON object: the two images cannot
// agree bit for bit -- fixed point against IEEE doubles, SplitMix against
// Lean's stdGen -- so what it reports is how far apart they are.

import { readFileSync, writeFileSync } from "node:fs";
import { encodePNG } from "./png.mjs";

export function readPPM(path) {
  const buf = readFileSync(path);

  // The header is ASCII whatever the format, and # starts a comment.
  let i = 0;
  const token = () => {
    for (;;) {
      while (i < buf.length && /\s/.test(String.fromCharCode(buf[i]))) i++;
      if (buf[i] === 0x23) { while (i < buf.length && buf[i] !== 0x0a) i++; continue; }
      break;
    }
    const start = i;
    while (i < buf.length && !/\s/.test(String.fromCharCode(buf[i]))) i++;
    return buf.toString("ascii", start, i);
  };

  const magic = token();
  if (magic !== "P3" && magic !== "P6") throw new Error(path + ": not a PPM (" + magic + ")");
  const width = Number(token()), height = Number(token()), maxval = Number(token());
  if (maxval !== 255) throw new Error(path + ": only 8-bit PPMs are read, maxval is " + maxval);

  const rgb = Buffer.alloc(3 * width * height);
  if (magic === "P6") {
    i++;                                  // exactly one whitespace byte follows
    buf.copy(rgb, 0, i, i + rgb.length);
    if (buf.length - i < rgb.length) throw new Error(path + ": short pixel data");
  } else {
    for (let n = 0; n < rgb.length; n++) {
      const t = token();
      if (t === "") throw new Error(path + ": short pixel data");
      rgb[n] = Number(t);
    }
  }
  return { width, height, rgb };
}

function diff(a, b) {
  if (a.width !== b.width || a.height !== b.height) {
    throw new Error(`size mismatch: ${a.width}x${a.height} vs ${b.width}x${b.height}`);
  }
  const n = a.rgb.length;
  const out = Buffer.alloc(n);
  let sum = 0, max = 0, within2 = 0, within8 = 0, within32 = 0;
  for (let k = 0; k < n; k++) {
    const d = Math.abs(a.rgb[k] - b.rgb[k]);
    sum += d;
    if (d > max) max = d;
    if (d <= 2) within2++;
    if (d <= 8) within8++;
    if (d <= 32) within32++;
    out[k] = Math.min(255, 4 * d);       // 4x, or the differences are invisible
  }
  const pct = (x) => +((100 * x) / n).toFixed(2);
  return {
    width: a.width, height: a.height,
    mean_abs_diff: +(sum / n).toFixed(3),
    max_abs_diff: max,
    channels_within_2: pct(within2),
    channels_within_8: pct(within8),
    channels_within_32: pct(within32),
    rgb: out,
  };
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "png") {
  const img = readPPM(rest[0]);
  writeFileSync(rest[1], encodePNG(img.rgb, img.width, img.height));
} else if (cmd === "diff") {
  const d = diff(readPPM(rest[0]), readPPM(rest[1]));
  if (rest[2]) writeFileSync(rest[2], encodePNG(d.rgb, d.width, d.height));
  const { rgb, ...stats } = d;
  console.log(JSON.stringify({ a: rest[0], b: rest[1], ...stats,
                               image: rest[2] ?? null }));
} else {
  console.error("usage: ppm.mjs png <in.ppm> <out.png> | diff <a.ppm> <b.ppm> [diff.png]");
  process.exit(2);
}
