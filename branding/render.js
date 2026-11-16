// Renders branding/render.html to PNG masters in branding/out/ (run: node branding/render.js from the repo root,
// with PLAYWRIGHT_BROWSERS_PATH pointing at an installed Chromium). make_assets.py turns them into app resources.
const path = require("path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1700, height: 2400 }, deviceScaleFactor: 1 });
  await page.goto("file://" + path.join(__dirname, "render.html"));
  await page.evaluate(() => document.fonts.ready);
  for (const id of ["icon", "banner", "splash"]) {
    await page.locator("#" + id).screenshot({ path: path.join(__dirname, "out", id + ".png"), omitBackground: true });
  }
  await browser.close();
})();
