// The four lanes from Figma "App Icon z", in its 512-unit space.
const PILLS = [
  { x: 133, y: 96, h: 168, from: "#f9cb3d", to: "#ef7617" },
  { x: 270, y: 63, h: 149, from: "#f5696b", to: "#e52929" },
  { x: 133, y: 286, h: 161, from: "#3ddf8c", to: "#17ab35" },
  { x: 270, y: 239, h: 201, from: "#c183f9", to: "#5631ed" },
];
function lanesSVG({ size, background = true, radius = 0.225, crop = false }) {
  const defs = PILLS.map((p, i) =>
    `<linearGradient id="g${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${p.from}"/><stop offset="1" stop-color="${p.to}"/></linearGradient>`).join("");
  const pills = PILLS.map((p, i) =>
    `<rect x="${p.x}" y="${p.y}" width="110" height="${p.h}" rx="55" fill="url(#g${i})"/>`).join("");
  const box = crop ? "123 53 266 404" : "0 0 512 512";
  const bg = background ? `<rect width="512" height="512" rx="${512 * radius}" fill="#111214"/>` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}" width="${size}" height="${crop ? size * 404 / 266 : size}"><defs>${defs}</defs>${bg}${pills}</svg>`;
}
module.exports = { lanesSVG };
