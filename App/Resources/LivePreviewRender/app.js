// The offscreen render surface `BlockImageRenderer` (App target) drives via
// `WKWebView.callAsyncJavaScript`. Every function here returns `{ width, height }` — the CSS pixel
// size of `#stage`'s content after rendering — so the native side can resize the web view to fit
// exactly before taking its snapshot, rather than screenshotting a page-sized rect full of margin.
//
// `mermaid.initialize` needs to run before every render, not just once at load: unlike the CSS
// variables `mdedApplyTheme` sets (which every element reads live), Mermaid bakes its theme into
// the SVG at render time, so a later dark/light switch needs a fresh `initialize` call with the
// new theme before the next `mermaid.render`. Cheap and idempotent to repeat — see `mdedApplyTheme`.
// `securityLevel: 'strict'` sanitizes HTML labels inside diagram text rather than trusting them —
// the CSP in index.html is the outer boundary, this is Mermaid's own inner one for the diagram
// *content* itself, which is user Markdown, not app code.

/// Applies `theme` (`{ foreground, border, headerBackground, isDark }`, built by
/// `BlockImageRenderer.themePayload(for:)`) to the page: CSS custom properties every rule in
/// index.html's `<style>` reads, plus Mermaid's own theme (which — unlike the CSS vars — has to be
/// set before each render call, not just once). Called at the top of every `mdedRender*` function
/// rather than once from Swift, so a render request can never race a theme update and paint with
/// the wrong one.
function mdedApplyTheme(theme) {
  const root = document.documentElement;
  root.style.setProperty("--mded-fg", theme.foreground);
  root.style.setProperty("--mded-border", theme.border);
  root.style.setProperty("--mded-header-bg", theme.headerBackground);
  mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: theme.isDark ? "dark" : "neutral" });
}

function measureStage() {
  const el = document.getElementById("stage");
  const rect = el.getBoundingClientRect();
  return { width: Math.ceil(rect.width), height: Math.ceil(rect.height) };
}

async function mdedRenderMath(latex, displayMode, theme) {
  mdedApplyTheme(theme);
  const el = document.getElementById("stage");
  el.style.width = "";
  el.innerHTML = "";
  try {
    katex.render(latex, el, { displayMode: displayMode, throwOnError: false, strict: "ignore" });
  } catch (e) {
    el.textContent = String(latex);
  }
  return measureStage();
}

async function mdedRenderTableHTML(tableHTML, theme, targetWidth) {
  mdedApplyTheme(theme);
  const el = document.getElementById("stage");
  // Unlike math/Mermaid (which size themselves naturally), a table stretches to fill the editor's
  // actual measure: `#stage` is `display: inline-block` (see index.html), which shrink-wraps to
  // its *content's* natural width — for a table with short cells, that's far narrower than the
  // column the editor actually has to offer. Forcing `#stage` itself to `targetWidth` and the
  // table to `width: 100%` (index.html) hands that width to the browser's own table layout, which
  // wraps individual cells only when their content genuinely can't fit their fair share — exactly
  // "wrapping only when content genuinely requires it," for free, from `table-layout: auto`.
  el.style.width = targetWidth > 0 ? targetWidth + "px" : "";
  el.innerHTML = tableHTML;
  return measureStage();
}

async function mdedRenderMermaid(code, elementID, theme) {
  mdedApplyTheme(theme);
  const el = document.getElementById("stage");
  el.style.width = "";
  el.innerHTML = "";
  try {
    const { svg } = await mermaid.render(elementID, code);
    el.innerHTML = svg;
  } catch (e) {
    el.innerHTML = "<pre style=\"color:#c00;font:12px monospace;white-space:pre-wrap;\">" +
      String(e && e.message ? e.message : e).replace(/[<>&]/g, function (c) {
        return c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&amp;";
      }) + "</pre>";
  }
  return measureStage();
}
