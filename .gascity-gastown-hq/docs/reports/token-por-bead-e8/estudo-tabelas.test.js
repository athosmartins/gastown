#!/usr/bin/env node
/* estudo-tabelas.test.js — ga-5c3msy: tests the table behaviour on the REAL generated Estudos page (jsdom), then proves the test
   itself bites by running it against mutants of the script and the stylesheet (each must be caught).
   usage: node estudo-tabelas.test.js <page.html>          needs the jsdom module; prints "<N> ok, 0 failed" on success. */
"use strict";
const fs = require("fs");
const vm = require("vm");
let JSDOM;
try { ({ JSDOM } = require("jsdom")); } catch (e) { console.error("estudo-tabelas.test: the jsdom module is required (npm i -g jsdom)"); process.exit(3); }

const PAGE = process.argv[2];
if (!PAGE || !fs.existsSync(PAGE)) { console.error("usage: node estudo-tabelas.test.js <page.html>"); process.exit(2); }
const ORIGINAL = fs.readFileSync(PAGE, "utf8");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function makeChecker() {
  const c = { ok: 0, failed: [], check(cond, msg) { if (cond) c.ok++; else c.failed.push(msg); } };
  return c;
}

// ---- pure logic (unit): runs against the script text embedded in the page being tested ----
function loadApi(html) {
  const m = /<script id="estudo-tabelas">([\s\S]*?)<\/script>/.exec(html);
  if (!m) throw new Error("the page has no <script id=\"estudo-tabelas\">");
  // evaluated in an empty vm context (no window, no document, no host globals): only the pure logic is exercised here
  const sandbox = { module: { exports: {} } };
  vm.runInNewContext(m[1], sandbox, { timeout: 5000 });
  return sandbox.module.exports;
}

function unit(api, t) {
  const n = (s) => api.parseNum(s);
  t.check(n("US$ 1.446") === 1446, "parseNum: 'US$ 1.446' is 1446 (pt-BR thousands)");
  t.check(n("39,3%") === 39.3, "parseNum: '39,3%' is 39.3 (pt-BR decimal)");
  t.check(n("62% (52–71)") === 62, "parseNum: leading number of '62% (52–71)'");
  t.check(n("1.597/braço (126 d)") === 1597, "parseNum: '1.597/braço (126 d)' is 1597");
  t.check(n("~ 6429,58") === 6429.58, "parseNum: approx prefix is skipped");
  t.check(n("−3") === -3, "parseNum: the unicode minus is a minus");
  t.check(isNaN(n("n/p")) && isNaN(n("")) && isNaN(n("—")), "parseNum: 'n/p', '' and '—' are not numbers");
  t.check(isNaN(n("dog Sonnet 5 xhigh")), "parseNum: a LABEL containing a digit is not a number");
  t.check(isNaN(n("wa-worker")), "parseNum: 'wa-worker' is not a number");
  t.check(api.colType(["95", "77", "n/p", "57"]) === "num", "colType: mostly-numbers with one 'n/p' is numeric");
  t.check(api.colType(["dog Sonnet 5", "wa-worker 5.5", "crew"]) === "text", "colType: labels are text");
  t.check(api.colType(["", ""]) === "text", "colType: an all-empty column is text");
  const sortNum = (dir) => ["3", "n/p", "10", "", "7"].slice().sort((a, b) => api.compareCells(a, b, "num", dir));
  t.check(JSON.stringify(sortNum(-1)) === JSON.stringify(["10", "7", "3", "n/p", ""]), "compareCells: desc puts unknown LAST");
  t.check(JSON.stringify(sortNum(1)) === JSON.stringify(["3", "7", "10", "n/p", ""]), "compareCells: asc ALSO puts unknown last");
  t.check(["b", "a10", "a2", ""].sort((x, y) => api.compareCells(x, y, "text", 1)).join("|") === "a2|a10|b|", "compareCells: text asc, natural digits, blank last");
  const fn = { type: "num", min: 50, max: null };
  t.check(api.matches("95", fn) && !api.matches("29", fn) && !api.matches("n/p", fn), "matches: a numeric range excludes a cell with no number");
  t.check(api.matches("n/p", { type: "num", min: null, max: null }), "matches: an empty range matches everything");
  t.check(api.matches("dog", { type: "text", set: new Set(["dog"]) }) && !api.matches("crew", { type: "text", set: new Set(["dog"]) }), "matches: text set");
  t.check(JSON.stringify(api.distinctCounts(["b", "a", "b", " a "])) === JSON.stringify([["a", 2], ["b", 2]]), "distinctCounts: trims, counts, ties break alphabetically");
}

// ---- DOM (integration) on the real page ----
async function load(html) {
  const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });
  const win = dom.window, doc = win.document;
  if (doc.readyState !== "complete") await new Promise((r) => win.addEventListener("load", r));
  return { dom, win, doc };
}
const tableWith = (doc, ...heads) => [...doc.querySelectorAll("table")].find((tb) => {
  const hs = [...tb.tHead.rows[tb.tHead.rows.length - 1].cells].map((h) => h.textContent.trim());
  return heads.every((h) => hs.includes(h));
});
const colOf = (tb, name) => [...tb.tHead.rows[tb.tHead.rows.length - 1].cells].findIndex((h) => h.textContent.trim() === name);
const th = (tb, name) => tb.tHead.rows[tb.tHead.rows.length - 1].cells[colOf(tb, name)];
const colText = (tb, name) => { const c = colOf(tb, name); return [...tb.tBodies[0].rows].map((r) => r.cells[c].textContent.trim()); };
const visible = (tb, name) => { const c = colOf(tb, name); return [...tb.tBodies[0].rows].filter((r) => r.style.display !== "none").map((r) => r.cells[c].textContent.trim()); };
const click = (win, el) => el.dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));
const rightClick = (win, el) => { const e = new win.MouseEvent("contextmenu", { bubbles: true, cancelable: true }); el.dispatchEvent(e); return e; };
const button = (pop, label) => [...pop.querySelectorAll("button")].find((b) => b.textContent === label);

async function dom(html, t) {
  const { win, doc } = await load(html);
  const tables = [...doc.querySelectorAll("table")];
  // the expected count comes from the report itself (one separator row per pipe table), not from a number typed here
  const mdPath = require("path").join(__dirname, "..", "token-por-bead-e8.md");
  const expected = fs.existsSync(mdPath) ? (fs.readFileSync(mdPath, "utf8").match(/^\|[ :|-]*-{3,}[ :|-]*\|$/gm) || []).length : 1;
  t.check(tables.length === expected && expected >= 1, `the page has one table per pipe table in the report (page ${tables.length}, report ${expected})`);
  t.check(tables.every((tb) => tb.parentElement.classList.contains("estudo-tw") && tb.classList.contains("estudo-t")), "every table is inside the scrolling wrapper");
  const css = (doc.getElementById("estudo-tabelas-css") || { textContent: "" }).textContent;
  t.check(/thead th\s*\{[^}]*position:\s*sticky/.test(css), "the header row is position:sticky");
  t.check(/\.estudo-tw\s*\{[^}]*overflow:\s*auto/.test(css), "the wrapper scrolls (the sticky header needs it)");
  t.check(!!doc.querySelector(".estudo-dica"), "the how-to line is shown above the first table");

  const comp = tableWith(doc, "papel", "US$ (7 d)");
  t.check(!!comp, "found the cost-composition table");
  if (comp) {
    const usd = "US$ (7 d)";
    click(win, th(comp, usd));
    t.check(colText(comp, "papel").join(",") === "wa-worker,crew,dog,gate-reviewer", "numeric column: the FIRST click sorts descending");
    t.check(th(comp, usd).getAttribute("data-sort") === "desc", "the header shows the sort direction");
    click(win, th(comp, usd));
    t.check(colText(comp, "papel").join(",") === "gate-reviewer,dog,crew,wa-worker", "the 2nd click inverts to ascending");
    click(win, th(comp, "papel"));
    t.check(colText(comp, "papel").join(",") === "crew,dog,gate-reviewer,wa-worker", "text column: the FIRST click sorts ascending");
    t.check(th(comp, usd).getAttribute("data-sort") === null, "sorting another column clears the old indicator");

    // right-click -> text filter
    const ev = rightClick(win, th(comp, "papel"));
    t.check(ev.defaultPrevented, "right-click on a column name suppresses the browser menu");
    let pop = doc.querySelector(".estudo-pop");
    t.check(!!pop, "right-click opens that column's filter");
    const boxes = pop ? [...pop.querySelectorAll("input[type=checkbox]")] : [];
    t.check(boxes.length === 4 && boxes.every((b) => b.checked), "the text filter lists every value, all ticked (= no filter)");
    t.check(pop && /\(1\)/.test(pop.textContent), "the text filter shows the count per value");
    // everything ticked + Aplicar must NOT count as a filter
    button(pop, "Aplicar").dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
    t.check(!th(comp, "papel").classList.contains("estudo-filtered") && !doc.querySelector(".estudo-pop"), "'everything ticked' leaves no filter and closes the popover");
    // untick two, apply
    rightClick(win, th(comp, "papel"));
    pop = doc.querySelector(".estudo-pop");
    [...pop.querySelectorAll("label")].forEach((l) => { if (/^ (dog|crew) /.test(l.textContent)) l.querySelector("input").checked = false; });
    button(pop, "Aplicar").dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
    t.check(visible(comp, "papel").join(",") === "gate-reviewer,wa-worker", "unticking values hides exactly those rows");
    t.check(th(comp, "papel").classList.contains("estudo-filtered"), "a filtered column is marked in the header");
    const cnt = comp.parentElement.nextElementSibling;   // this table's own counter, not the first one on the page
    t.check(cnt && cnt.classList.contains("estudo-n") && cnt.style.display !== "none" && /2 de 4/.test(cnt.textContent), "the row counter under the table says 2 of 4");
    // sorting keeps the filter
    click(win, th(comp, usd));
    t.check(visible(comp, "papel").length === 2, "sorting does not undo a filter");
    // Limpar
    rightClick(win, th(comp, "papel"));
    button(doc.querySelector(".estudo-pop"), "Limpar").dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
    t.check(visible(comp, "papel").length === 4 && !th(comp, "papel").classList.contains("estudo-filtered"), "'Limpar' removes the filter");
    // Esc closes
    rightClick(win, th(comp, "papel"));
    doc.dispatchEvent(new win.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    t.check(!doc.querySelector(".estudo-pop"), "Esc closes the filter");
  }

  const coh = tableWith(doc, "coorte", "beads");
  t.check(!!coh, "found the cohort table");
  if (coh) {
    click(win, th(coh, "beads"));
    t.check(colText(coh, "beads").join(",") === "95,77,57,29,24,7", "cohort table: 'beads' sorts numerically, not as text");
    rightClick(win, th(coh, "beads"));
    const pop = doc.querySelector(".estudo-pop");
    const min = pop && pop.querySelector("input[data-role=min]");
    t.check(!!min, "a numeric column's filter is a from/to range");
    if (min) {
      min.value = "50";
      button(pop, "Aplicar").dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
      t.check(visible(coh, "beads").join(",") === "95,77,57", "from 50: only the rows >= 50 stay");
    }
  }

  // touch: hold ~550 ms opens the filter; the click that follows must not also sort; a short tap does not open it
  const t2 = tableWith(doc, "papel", "US$ (7 d)");
  if (t2) {
    const head = th(t2, "entrada nova");
    const before = colText(t2, "papel").join(",");
    head.dispatchEvent(new win.Event("touchstart", { bubbles: true }));
    head.dispatchEvent(new win.Event("touchend", { bubbles: true }));
    await sleep(700);
    t.check(!doc.querySelector(".estudo-pop"), "a short tap does not open the filter");
    head.dispatchEvent(new win.Event("touchstart", { bubbles: true }));
    await sleep(700);
    t.check(!!doc.querySelector(".estudo-pop"), "holding ~550 ms opens the filter");
    head.dispatchEvent(new win.Event("touchend", { bubbles: true }));
    click(win, head);
    t.check(colText(t2, "papel").join(",") === before && head.getAttribute("data-sort") === null, "the click after a long press does not also sort");
  }
  win.close();
}

// ---- mutants: each one breaks a behaviour on purpose; the run against it must report a failure ----
const MUTANTS = [
  { name: "a numeric column starts ascending", from: '(types[c] === "num" ? -1 : 1)', to: "1" },
  { name: "everything-ticked still creates a filter", from: "filters[col] = all ? null : { type: \"text\", set: set };", to: "filters[col] = { type: \"text\", set: set };" },
  { name: "unknown cells sort first when ascending", from: "if (ea || eb) return ea === eb ? 0 : (ea ? 1 : -1);\n      return na === nb", to: "if (ea || eb) return ea === eb ? 0 : (ea ? -1 : 1);\n      return na === nb" },
  { name: "a label with a digit parses as a number", from: "/^(?:US\\$|R\\$|[~≈≥≤<>+]|\\s)*(-?\\d[\\d.,]*)/", to: "/^[^\\d-]*(-?\\d[\\d.,]*)/" },
  { name: "the click after a long press sorts too", from: "if (th._lp) { th._lp = false; return; }", to: "if (th._lp) { th._lp = false; }" },
  { name: "the header is not sticky", from: "position: sticky; top: 0;", to: "position: static; top: 0;" },
  { name: "pt-BR thousands read as a decimal", from: "else if (/^-?\\d{1,3}(\\.\\d{3})+$/.test(t)) t = t.replace(/\\./g, \"\");", to: "" },
];

(async () => {
  const main = makeChecker();
  unit(loadApi(ORIGINAL), main);
  await dom(ORIGINAL, main);
  if (main.failed.length) {
    main.failed.forEach((f) => console.error("  ✗ " + f));
    console.error(`${main.ok} ok, ${main.failed.length} failed`);
    process.exit(1);
  }
  let total = main.ok;
  for (const mu of MUTANTS) {
    const at = ORIGINAL.indexOf(mu.from);
    if (at < 0 || ORIGINAL.indexOf(mu.from, at + 1) >= 0) { console.error(`  ✗ mutant '${mu.name}' does not apply exactly once — the test is out of sync with the script`); process.exit(1); }
    const t = makeChecker();
    try { unit(loadApi(ORIGINAL.replace(mu.from, mu.to)), t); await dom(ORIGINAL.replace(mu.from, mu.to), t); }
    catch (e) { t.failed.push("threw: " + e.message); }
    if (!t.failed.length) { console.error(`  ✗ mutant '${mu.name}' SURVIVED — no check caught it`); process.exit(1); }
    console.log(`  ✓ mutant '${mu.name}' rejected (${t.failed.length} check(s) failed against it)`);
    total++;
  }
  console.log(`\n${total} ok, 0 failed`);
})().catch((e) => { console.error(e); process.exit(1); });
