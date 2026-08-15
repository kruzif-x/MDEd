// The offscreen render surface `BlockImageRenderer` (App target) drives via
// `WKWebView.callAsyncJavaScript`. Every function here returns `{ width, height }` — the CSS pixel
// size of `#stage`'s content after rendering — so the native side can resize the web view to fit
// exactly before taking its snapshot, rather than screenshotting a page-sized rect full of margin.
//
// `mermaid.initialize` runs once, at load, with `securityLevel: 'strict'` (HTML labels inside
// diagram text are sanitized rather than trusted) — the CSP in index.html is the outer boundary,
// this is Mermaid's own inner one for the diagram *content* itself, which is user Markdown, not
// app code.
mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "neutral" });

function measureStage() {
  const el = document.getElementById("stage");
  const rect = el.getBoundingClientRect();
  return { width: Math.ceil(rect.width), height: Math.ceil(rect.height) };
}

async function mdedRenderMath(latex, displayMode) {
  const el = document.getElementById("stage");
  el.innerHTML = "";
  try {
    katex.render(latex, el, { displayMode: displayMode, throwOnError: false, strict: "ignore" });
  } catch (e) {
    el.textContent = String(latex);
  }
  return measureStage();
}

async function mdedRenderTableHTML(tableHTML) {
  const el = document.getElementById("stage");
  el.innerHTML = tableHTML;
  return measureStage();
}

async function mdedRenderMermaid(code, elementID) {
  const el = document.getElementById("stage");
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
