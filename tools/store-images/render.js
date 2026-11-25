const { chromium } = require("playwright");
const path = require("path");
const { lanesSVG } = require("./lanes.js");
const OUT = process.argv[2];
const EXT = process.argv[3]; // http URL of the extension folder

const font = `font-family: Inter, system-ui, sans-serif;`;
const page = (w, h, body, css = "") => `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:${w}px;height:${h}px;overflow:hidden;${font}-webkit-font-smoothing:antialiased}
body{background:#0e0f11;color:#f3f1ec}
.glow{position:absolute;inset:0;background:
 radial-gradient(600px 400px at 18% 30%, rgba(249,203,61,.10), transparent 70%),
 radial-gradient(700px 500px at 85% 80%, rgba(86,49,237,.16), transparent 70%),
 radial-gradient(500px 400px at 70% 10%, rgba(229,41,41,.08), transparent 70%)}
${css}</style></head><body><div class="glow"></div>${body}</body></html>`;

async function shoot(browser, w, h, html, file, { alpha = false } = {}) {
  const p = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  await p.setContent(html);
  await p.evaluate(() => document.fonts.ready);
  await p.screenshot({ path: path.join(OUT, file), omitBackground: alpha });
  await p.close();
}

(async () => {
  const browser = await chromium.launch();

  // Toolbar and store icons. A faint white edge and glow keep the dark tile visible on dark backgrounds. The store icon keeps 16 px of transparent padding around 96 px of art.
  for (const n of [16, 32, 48]) {
    await shoot(browser, n, n, `<html><body style="margin:0;background:transparent">${lanesSVG({ size: n, radius: 0.24 })}</body></html>`,
      `icon-${n}.png`, { alpha: true });
  }
  await shoot(browser, 128, 128,
    `<html><body style="margin:0;background:transparent"><div style="margin:16px;width:96px;height:96px;border-radius:23px;box-shadow:0 0 0 1px rgba(255,255,255,.22),0 0 6px 1px rgba(255,255,255,.18)">${lanesSVG({ size: 96, radius: 0.24 })}</div></body></html>`,
    "icon-128.png", { alpha: true });

  // The real popup, rendered with a stubbed Chrome API in the connected state.
  const popup = await browser.newPage({ viewport: { width: 352, height: 300 }, deviceScaleFactor: 2, colorScheme: "dark" });
  await popup.addInitScript(() => {
    window.chrome = {
      runtime: { sendMessage: async () => ({ enabled: true, connected: true, tracking: true, error: null,
        id: "lkckmlojgpfflmkhkaapcijpjehdmobo" }) },
      storage: { local: { get: async () => ({ alias: "Client Work" }), set: async () => {} } },
    };
  });
  await popup.goto(`${EXT}/settings.html`);
  await popup.waitForFunction(() => document.querySelector("#status").dataset.state === "tracking");
  await popup.evaluate(() => { document.body.style.background = "#202124"; document.querySelector("#id").textContent = ""; });
  const box = await popup.locator("body").boundingBox();
  const mainBox = await popup.locator("main").boundingBox();
  const popupW = Math.ceil(box.width);
  const popupPNG = await popup.screenshot({ clip: { x: 0, y: 0, width: popupW, height: Math.ceil(mainBox.height) } });
  const popupH = Math.ceil(mainBox.height);
  await popup.close();
  const popupURL = `data:image/png;base64,${popupPNG.toString("base64")}`;

  // Screenshot, 1280 x 800: the popup over a browser window, next to the lanes it feeds.
  const lane = (label, color, blocks) => `<div class="lane"><div class="lh"><i style="background:${color}"></i>${label}</div>${
    blocks.map(([top, h, t, c]) => `<div class="blk" style="top:${top}px;height:${h}px;background:${c}"><b>${t}</b></div>`).join("")}</div>`;
  await shoot(browser, 1280, 800, page(1280, 800, `
    <div class="copy">
      ${lanesSVG({ size: 64, radius: 0.24 })}
      <h1>Every site you work on,<br>in the right lane.</h1>
      <p>Daylanes sees which site is open in your active tab and files the time under the right client and project. Nothing leaves your Mac.</p>
      <ul><li>Only the site and path, never page content</li><li>One label per browser profile, such as Work or Personal</li><li>Pause sharing for any profile from the popup</li></ul>
    </div>
    <div class="win">
      <div class="bar"><span></span><span></span><span></span><div class="url">mail.google.com/mail/u/0/</div><div class="ext">${lanesSVG({ size: 18, radius: 0.24 })}</div></div>
      <div class="sk"><i style="width:38%"></i><i style="width:72%"></i><i style="width:64%"></i><i style="width:70%"></i><i style="width:55%"></i><i style="width:68%"></i></div>
      <img class="pop" src="${popupURL}" style="width:${popupW * 1.15}px;height:${popupH * 1.15}px">
    </div>
    <div class="app">
      <div class="abar"><span></span><span></span><span></span><b>Daylanes · Today</b></div>
      <div class="day">
        ${lane("You", "#f3f1ec", [[0, 70, "Gmail · Lumen Labs", "linear-gradient(#f9cb3d,#ef7617)"], [80, 46, "Figma · Lumen Labs", "linear-gradient(#f9cb3d,#ef7617)"], [136, 74, "github.com · Vela Foods", "linear-gradient(#3ddf8c,#17ab35)"]])}
        ${lane("Codex", "#f5696b", [[30, 110, "Vela Foods · PR #42", "linear-gradient(#c183f9,#5631ed)"], [150, 60, "Lumen Labs", "linear-gradient(#f5696b,#e52929)"]])}
      </div>
    </div>`, `
    .copy{position:absolute;left:72px;top:170px;width:470px}
    h1{font-size:40px;line-height:1.14;letter-spacing:-.02em;margin:26px 0 18px;font-weight:700}
    p{font-size:19px;line-height:1.5;color:#c9c6bf;margin:0 0 22px}
    ul{margin:0;padding:0;list-style:none;font-size:16px;color:#e7e4dd}
    li{margin:10px 0;padding-left:22px;position:relative}
    li::before{content:"";position:absolute;left:0;top:6px;width:8px;height:12px;border-radius:4px;background:linear-gradient(#c183f9,#5631ed)}
    .win{position:absolute;left:600px;top:80px;width:620px;height:440px;border-radius:14px;background:#17181b;
      box-shadow:0 30px 80px rgba(0,0,0,.55),0 0 0 1px rgba(255,255,255,.07);overflow:hidden}
    .bar{height:44px;background:#202124;display:flex;align-items:center;gap:8px;padding:0 14px}
    .bar span{width:12px;height:12px;border-radius:50%;background:#3c3d41}
    .url{flex:1;margin-left:14px;height:28px;border-radius:14px;background:#2d2e31;color:#bdbbb6;font-size:13px;display:flex;align-items:center;padding-left:14px}
    .ext{width:28px;height:28px;border-radius:6px;background:#3a3b3f;display:flex;align-items:center;justify-content:center}
    .sk{padding:28px 30px}
    .sk i{display:block;height:14px;border-radius:7px;background:#2a2b2f;margin:0 0 20px}
    .app{position:absolute;left:560px;top:430px;width:400px;height:300px;border-radius:12px;background:#1b1c1f;
      box-shadow:0 30px 80px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.08);overflow:hidden}
    .abar{height:38px;display:flex;align-items:center;gap:8px;padding:0 14px;border-bottom:1px solid rgba(255,255,255,.06)}
    .abar span{width:11px;height:11px;border-radius:50%;background:#3c3d41}
    .abar b{margin-left:10px;font-size:13px;color:#e7e4dd;font-weight:600}
    .day{position:absolute;left:18px;top:54px;display:flex;gap:12px}
    .lane{position:relative;width:176px;height:230px}
    .lh{font-size:13px;color:#bdbbb6;display:flex;align-items:center;gap:7px}
    .lh i{width:8px;height:8px;border-radius:50%}
    .blk{position:absolute;left:0;right:0;margin-top:26px;border-radius:9px;padding:8px 10px;box-sizing:border-box}
    .blk b{font-size:12px;font-weight:600;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.35)}
    .pop{position:absolute;right:14px;top:50px;border-radius:10px;box-shadow:0 18px 50px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.08)}
  `), "screenshot-1280x800.png");

  // Promo tiles.
  const tile = (w, h, art, title, sub, css) => page(w, h, `<div class="t">${art}<div><h1>${title}</h1><p>${sub}</p></div></div>`, css);
  await shoot(browser, 440, 280, tile(440, 280, lanesSVG({ size: 112, radius: 0.24 }), "Daylanes", "Your browser time, filed under the right project.", `
    .t{position:absolute;inset:0;display:flex;align-items:center;gap:26px;padding:0 36px}
    h1{font-size:40px;margin:0 0 8px;letter-spacing:-.02em;font-weight:700}
    p{font-size:16px;line-height:1.4;margin:0;color:#c9c6bf}`), "promo-small-440x280.png");
  await shoot(browser, 1400, 560, tile(1400, 560, lanesSVG({ size: 300, background: false, crop: true }), "Daylanes",
    "Time tracking for Mac that knows<br>which site you’re working on.<br>Private by design: nothing leaves your computer.", `
    .t{position:absolute;inset:0;display:flex;align-items:center;gap:90px;padding:0 140px}
    h1{font-size:96px;margin:0 0 18px;letter-spacing:-.03em;font-weight:700}
    p{font-size:26px;line-height:1.45;margin:0;color:#c9c6bf}`), "promo-marquee-1400x560.png");

  await browser.close();
})();
