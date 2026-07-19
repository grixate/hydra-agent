"use strict";

const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");
const { chromium } = require("playwright");

const baseUrl = (process.env.HYDRA_A11Y_BASE_URL || "http://127.0.0.1:4000").replace(/\/$/, "");
const routes = (process.env.HYDRA_A11Y_PATHS || process.argv.slice(2).join(",") || "/simulations,/blueprints,/settings/privacy")
  .split(",")
  .map((route) => route.trim())
  .filter(Boolean);
const screenshotDir = process.env.HYDRA_A11Y_SCREENSHOT_DIR;
const email = process.env.HYDRA_A11Y_EMAIL;
const password = process.env.HYDRA_A11Y_PASSWORD;
const includeTree = process.env.HYDRA_A11Y_INCLUDE_TREE === "1";
const browserExecutable = process.env.HYDRA_A11Y_BROWSER_EXECUTABLE;
const verbose = process.env.HYDRA_A11Y_VERBOSE === "1";
const summaryOnly = process.env.HYDRA_A11Y_SUMMARY_ONLY === "1";

function absoluteUrl(route) {
  return new URL(route, `${baseUrl}/`).toString();
}

function safeName(route, viewport) {
  const routeName = route.replace(/^https?:\/\/[^/]+/i, "").replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "home";
  return `${routeName}-${viewport}.png`;
}

async function signIn(page) {
  if (!email || !password) return;

  await page.goto(absoluteUrl("/login"), { waitUntil: "domcontentloaded" });
  await page.locator('input[name="session[email]"]').fill(email);
  await page.locator('input[name="session[password]"]').fill(password);
  await Promise.all([
    page.waitForURL((url) => url.pathname !== "/login"),
    page.getByRole("button", { name: /sign in/i }).click(),
  ]);
}

async function inspectDom(page) {
  return page.evaluate(() => {
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
    };

    const textForIds = (value) => (value || "")
      .split(/\s+/)
      .filter(Boolean)
      .map((id) => document.getElementById(id)?.textContent?.trim() || "")
      .join(" ")
      .trim();

    const accessibleName = (element) => {
      const labelled = textForIds(element.getAttribute("aria-labelledby"));
      if (labelled) return labelled;
      const aria = element.getAttribute("aria-label")?.trim();
      if (aria) return aria;
      if (element.labels?.length) {
        const label = Array.from(element.labels).map((item) => item.textContent?.trim()).join(" ").trim();
        if (label) return label;
      }
      if (element.tagName === "IMG") return element.getAttribute("alt")?.trim() || "";
      if (element.tagName === "INPUT" && ["button", "submit", "reset"].includes(element.type)) {
        return element.value?.trim() || "";
      }
      return element.textContent?.trim() || element.getAttribute("title")?.trim() || "";
    };

    const ids = Array.from(document.querySelectorAll("[id]"), (element) => element.id).filter(Boolean);
    const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
    const namedSelector = "a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link]";
    const unnamedControls = Array.from(document.querySelectorAll(namedSelector))
      .filter(visible)
      .filter((element) => !accessibleName(element))
      .map((element) => `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}`);

    const brokenAriaReferences = [];
    for (const element of document.querySelectorAll("[aria-labelledby],[aria-describedby],[aria-controls],[aria-owns]")) {
      for (const attribute of ["aria-labelledby", "aria-describedby", "aria-controls", "aria-owns"]) {
        const value = element.getAttribute(attribute);
        if (!value) continue;
        for (const id of value.split(/\s+/).filter(Boolean)) {
          if (!document.getElementById(id)) brokenAriaReferences.push(`${attribute}:${id}`);
        }
      }
    }

    const headings = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,h6")).filter(visible);
    const headingLevels = headings.map((heading) => Number(heading.tagName.slice(1)));
    const headingJumps = headingLevels
      .map((level, index) => ({ from: headingLevels[index - 1], to: level, text: headings[index].textContent?.trim().slice(0, 80) }))
      .filter((item, index) => index > 0 && item.to > item.from + 1);

    const imagesWithoutAlt = Array.from(document.querySelectorAll("img:not([alt])")).filter(visible).length;
    const unnamedCanvases = Array.from(document.querySelectorAll("canvas")).filter(visible).filter((item) => !accessibleName(item)).length;
    const tablesWithoutHeaders = Array.from(document.querySelectorAll("table")).filter(visible).filter((table) => !table.querySelector("th")).length;
    const targetSelector = "button,input:not([type=hidden]),select,textarea,summary,[role=button]";
    const targetRect = (element) => {
      const candidates = [element, ...Array.from(element.labels || [])].filter(visible);
      return candidates
        .map((candidate) => candidate.getBoundingClientRect())
        .sort((left, right) => (right.width * right.height) - (left.width * left.height))[0];
    };
    const undersizedTargets = Array.from(document.querySelectorAll(targetSelector))
      .filter(visible)
      .map((element) => {
        const rect = targetRect(element);
        return {
          name: accessibleName(element).slice(0, 80),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        };
      })
      .filter((item) => item.width < 24 || item.height < 24);

    return {
      lang: document.documentElement.lang,
      title: document.title,
      mainLandmarks: document.querySelectorAll("main").length,
      h1Count: headings.filter((heading) => heading.tagName === "H1").length,
      duplicateIds,
      unnamedControls,
      brokenAriaReferences: [...new Set(brokenAriaReferences)],
      headingJumps,
      imagesWithoutAlt,
      unnamedCanvases,
      tablesWithoutHeaders,
      undersizedTargets,
      horizontalOverflowPx: Math.max(document.documentElement.scrollWidth - document.documentElement.clientWidth, 0),
    };
  });
}

async function inspectKeyboard(page) {
  await page.locator("body").click({ position: { x: 1, y: 1 } });
  const samples = [];

  for (let index = 0; index < 20; index += 1) {
    await page.keyboard.press("Tab");
    const sample = await page.evaluate(() => {
      const element = document.activeElement;
      if (!element || element === document.body) return null;
      const style = window.getComputedStyle(element);
      return {
        tag: element.tagName.toLowerCase(),
        id: element.id || null,
        className: typeof element.className === "string" ? element.className : null,
        visible: element.getBoundingClientRect().width > 0 && element.getBoundingClientRect().height > 0,
        focusVisible: element.matches(":focus-visible"),
        indicator: parseFloat(style.outlineWidth || "0") >= 2 || style.boxShadow !== "none",
      };
    });

    if (sample) samples.push(sample);
  }

  return {
    samples: samples.length,
    invisibleFocus: samples.filter((sample) => !sample.visible).length,
    missingFocusIndicators: samples.filter((sample) => sample.focusVisible && !sample.indicator).length,
    firstTarget: samples[0] || null,
  };
}

function failuresFor(result) {
  const failures = [];
  if (result.status < 200 || result.status >= 400) failures.push(`HTTP ${result.status}`);
  if (result.actualPath !== result.expectedPath) failures.push(`unexpected navigation to ${result.actualPath}`);
  if (!["en", "ru"].includes(result.dom.lang)) failures.push("document language is missing or unsupported");
  if (result.dom.mainLandmarks !== 1) failures.push(`expected one main landmark, found ${result.dom.mainLandmarks}`);
  if (result.dom.h1Count !== 1) failures.push(`expected one visible h1, found ${result.dom.h1Count}`);
  if (result.dom.duplicateIds.length) failures.push("duplicate IDs");
  if (result.dom.unnamedControls.length) failures.push("unnamed interactive controls");
  if (result.dom.brokenAriaReferences.length) failures.push("broken ARIA references");
  if (result.dom.headingJumps.length) failures.push("heading-level jumps");
  if (result.dom.imagesWithoutAlt) failures.push("images without alt attributes");
  if (result.dom.unnamedCanvases) failures.push("canvases without text names");
  if (result.dom.tablesWithoutHeaders) failures.push("tables without headers");
  if (result.dom.undersizedTargets.length) failures.push("controls below 24×24 CSS pixels");
  if (result.dom.horizontalOverflowPx) failures.push("horizontal document overflow");
  if (result.keyboard.invisibleFocus) failures.push("keyboard focus moved to hidden content");
  if (result.keyboard.missingFocusIndicators) failures.push("visible keyboard focus indicator missing");
  if (!result.accessibilityTreeCharacters) failures.push("empty accessibility tree");
  if (result.consoleErrors.length) failures.push("browser console errors");
  return failures;
}

async function inspectRoute(context, route, viewportName, viewport) {
  const page = await context.newPage();
  await page.setViewportSize(viewport);
  const consoleErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text().slice(0, 500));
  });
  page.on("pageerror", (error) => consoleErrors.push(error.message.slice(0, 500)));

  const response = await page.goto(absoluteUrl(route), { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(250);
  await page.emulateMedia({ reducedMotion: "reduce" });
  const dom = await inspectDom(page);
  const keyboard = await inspectKeyboard(page);
  const ariaSnapshot = await page.locator("body").ariaSnapshot();

  if (screenshotDir) {
    fs.mkdirSync(screenshotDir, { recursive: true });
    await page.screenshot({ path: path.join(screenshotDir, safeName(route, viewportName)), fullPage: true });
  }

  const result = {
    route,
    finalUrl: page.url(),
    expectedPath: new URL(absoluteUrl(route)).pathname,
    actualPath: new URL(page.url()).pathname,
    viewport: viewportName,
    status: response?.status() || 0,
    dom,
    keyboard,
    accessibilityTreeCharacters: ariaSnapshot.length,
    accessibilityTreeSha256: crypto.createHash("sha256").update(ariaSnapshot).digest("hex"),
    consoleErrors,
  };
  if (includeTree) result.ariaSnapshot = ariaSnapshot;
  result.failures = failuresFor(result);
  await page.close();

  if (verbose) return result;

  return {
    route: result.route,
    finalUrl: result.finalUrl,
    viewport: result.viewport,
    status: result.status,
    document: {
      lang: dom.lang,
      title: dom.title,
      mainLandmarks: dom.mainLandmarks,
      h1Count: dom.h1Count,
      horizontalOverflowPx: dom.horizontalOverflowPx,
    },
    violationCounts: {
      duplicateIds: dom.duplicateIds.length,
      unnamedControls: dom.unnamedControls.length,
      brokenAriaReferences: dom.brokenAriaReferences.length,
      headingJumps: dom.headingJumps.length,
      imagesWithoutAlt: dom.imagesWithoutAlt,
      unnamedCanvases: dom.unnamedCanvases,
      tablesWithoutHeaders: dom.tablesWithoutHeaders,
      undersizedTargets: dom.undersizedTargets.length,
      invisibleFocus: keyboard.invisibleFocus,
      missingFocusIndicators: keyboard.missingFocusIndicators,
      consoleErrors: consoleErrors.length,
    },
    accessibilityTreeCharacters: result.accessibilityTreeCharacters,
    accessibilityTreeSha256: result.accessibilityTreeSha256,
    failures: result.failures,
  };
}

async function main() {
  if ((email && !password) || (!email && password)) {
    throw new Error("HYDRA_A11Y_EMAIL and HYDRA_A11Y_PASSWORD must be provided together");
  }

  const browser = await chromium.launch({
    headless: true,
    ...(browserExecutable ? { executablePath: browserExecutable } : {}),
  });
  const context = await browser.newContext();

  try {
    const loginPage = await context.newPage();
    await signIn(loginPage);
    await loginPage.close();

    const results = [];
    for (const route of routes) {
      results.push(await inspectRoute(context, route, "desktop", { width: 1280, height: 900 }));
      results.push(await inspectRoute(context, route, "mobile", { width: 390, height: 844 }));
      results.push(await inspectRoute(context, route, "high-zoom", { width: 320, height: 720 }));
    }

    const violationTotals = results.reduce((totals, result) => {
      for (const [name, count] of Object.entries(result.violationCounts || {})) {
        totals[name] = (totals[name] || 0) + count;
      }
      return totals;
    }, {});

    const summary = {
      schemaVersion: 1,
      auditedAt: new Date().toISOString(),
      baseUrl,
      authenticated: Boolean(email),
      routes,
      checks: results.length,
      passed: results.filter((result) => result.failures.length === 0).length,
      failed: results.filter((result) => result.failures.length > 0).length,
      violationTotals,
      results: summaryOnly
        ? results.map((result) => ({
            route: result.route,
            viewport: result.viewport,
            status: result.status,
            accessibilityTreeSha256: result.accessibilityTreeSha256,
            failures: result.failures,
          }))
        : results,
    };

    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
    if (summary.failed) process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  process.stderr.write(`Accessibility audit failed: ${error.message}\n`);
  process.exitCode = 1;
});
