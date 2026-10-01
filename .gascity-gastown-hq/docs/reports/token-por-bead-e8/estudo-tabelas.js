/* estudo-tabelas.js — ga-5c3msy: the canonical table behaviour (wa-6qnv9) for a static Estudos page.
   1. click a column name -> sorts (a numeric column starts DESCENDING, a text column ASCENDING; a 2nd click inverts);
   2. right-click (or hold ~550 ms on touch) a column name -> that column's filter: text = search + multi-select with counts,
      number = from/to. "Everything ticked" means no filter, and a filtered column is marked in the header;
   3. the header row stays put while the table scrolls (position: sticky inside the wrapper that does the scrolling).
   The pure logic comes first and is exported for the node test; the DOM glue below only runs where there is a document. */
(function (root) {
  "use strict";

  var LONG_PRESS_MS = 550;

  /* ---------- pure logic ---------- */

  // pt-BR number at the START of a cell ("US$ 1.446", "39,3%", "62% (52–71)", "1.597/braço (126 d)"). A label that merely contains a
  // digit ("dog Sonnet 5 xhigh") is NOT a number, or every label column would sort by its embedded digit.
  function parseNum(text) {
    var s = String(text == null ? "" : text).replace(/−/g, "-").trim();
    var m = /^(?:US\$|R\$|[~≈≥≤<>+]|\s)*(-?\d[\d.,]*)/.exec(s);
    if (!m) return NaN;
    var t = m[1].replace(/[.,]+$/, "");
    if (t.indexOf(",") >= 0) t = t.replace(/\./g, "").replace(",", ".");
    else if (/^-?\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, "");
    var n = parseFloat(t);
    return isNaN(n) ? NaN : n;
  }

  // a column is numeric when most of its non-empty cells are ("n/p" and "—" cells are allowed to be the minority)
  function colType(values) {
    var filled = values.filter(function (v) { return String(v).trim() !== ""; });
    if (!filled.length) return "text";
    var nums = filled.filter(function (v) { return !isNaN(parseNum(v)); });
    return nums.length / filled.length >= 0.6 ? "num" : "text";
  }

  // dir: 1 ascending, -1 descending. Empty / non-numeric cells go LAST in both directions: a blank is "unknown", not the smallest.
  function compareCells(a, b, type, dir) {
    var ea = String(a).trim() === "", eb = String(b).trim() === "";
    if (type === "num") {
      var na = parseNum(a), nb = parseNum(b);
      ea = isNaN(na); eb = isNaN(nb);
      if (ea || eb) return ea === eb ? 0 : (ea ? 1 : -1);
      return na === nb ? 0 : (na < nb ? -dir : dir);
    }
    if (ea || eb) return ea === eb ? 0 : (ea ? 1 : -1);
    return dir * String(a).localeCompare(String(b), "pt-BR", { numeric: true, sensitivity: "base" });
  }

  // filter: null (none) | {type:"text", set:Set of allowed cell texts} | {type:"num", min:number|null, max:number|null}
  function matches(value, f) {
    if (!f) return true;
    if (f.type === "num") {
      var n = parseNum(value);
      if (isNaN(n)) return f.min == null && f.max == null;   // a cell with no number is not inside any range
      return (f.min == null || n >= f.min) && (f.max == null || n <= f.max);
    }
    return f.set.has(String(value).trim());
  }

  function distinctCounts(values) {
    var m = Object.create(null);
    values.forEach(function (v) { v = String(v).trim(); m[v] = (m[v] || 0) + 1; });
    return Object.keys(m).map(function (k) { return [k, m[k]]; }).sort(function (x, y) {
      return y[1] - x[1] || x[0].localeCompare(y[0], "pt-BR", { numeric: true, sensitivity: "base" });
    });
  }

  /* ---------- DOM glue ---------- */

  function closePop(doc) {
    var p = doc.querySelector(".estudo-pop");
    if (p && p.parentNode) p.parentNode.removeChild(p);
  }

  function mk(doc, tag, cls, text) {
    var e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function enhance(table) {
    var doc = table.ownerDocument;
    var head = table.tHead, body = table.tBodies[0];
    if (!head || !body || !head.rows.length || !body.rows.length) return null;
    var ths = [].slice.call(head.rows[head.rows.length - 1].cells);
    var rows = [].slice.call(body.rows);
    var cells = rows.map(function (r) {
      return [].map.call(r.cells, function (c) { return c.textContent.replace(/\s+/g, " ").trim(); });
    });
    var types = ths.map(function (_, c) { return colType(cells.map(function (r) { return r[c] || ""; })); });
    var filters = ths.map(function () { return null; });
    var sort = { col: -1, dir: 1 };

    var wrap = mk(doc, "div", "estudo-tw");
    table.parentNode.insertBefore(wrap, table);
    wrap.appendChild(table);
    table.classList.add("estudo-t");
    var counter = mk(doc, "div", "estudo-n");
    counter.style.display = "none";
    wrap.parentNode.insertBefore(counter, wrap.nextSibling);

    function sortBy(col, dir) {
      sort = { col: col, dir: dir };
      var order = rows.map(function (_, i) { return i; });
      order.sort(function (a, b) { return compareCells(cells[a][col] || "", cells[b][col] || "", types[col], dir) || (a - b); });
      order.forEach(function (i) { body.appendChild(rows[i]); });
      ths.forEach(function (th, j) {
        if (j === col) th.setAttribute("data-sort", dir > 0 ? "asc" : "desc"); else th.removeAttribute("data-sort");
      });
    }

    function applyFilters() {
      var shown = 0;
      rows.forEach(function (r, i) {
        var ok = filters.every(function (f, c) { return matches(cells[i][c] || "", f); });
        r.style.display = ok ? "" : "none";
        if (ok) shown++;
      });
      ths.forEach(function (th, c) { th.classList.toggle("estudo-filtered", !!filters[c]); });
      var any = filters.some(Boolean);
      counter.textContent = any ? shown + " de " + rows.length + " linhas (filtro ativo)" : "";
      counter.style.display = any ? "" : "none";
    }

    function openFilter(col, th) {
      closePop(doc);
      var f = filters[col];
      var pop = mk(doc, "div", "estudo-pop");
      pop.setAttribute("role", "dialog");
      pop.appendChild(mk(doc, "div", "estudo-pop-t", th.textContent.trim()));
      var apply;
      if (types[col] === "num") {
        var lo = mk(doc, "input"), hi = mk(doc, "input");
        lo.placeholder = "de"; hi.placeholder = "até";
        lo.value = f && f.min != null ? String(f.min) : ""; hi.value = f && f.max != null ? String(f.max) : "";
        lo.setAttribute("data-role", "min"); hi.setAttribute("data-role", "max");
        var row = mk(doc, "div", "estudo-pop-r"); row.appendChild(lo); row.appendChild(hi); pop.appendChild(row);
        apply = function () {
          var a = parseNum(lo.value), b = parseNum(hi.value);
          filters[col] = (isNaN(a) && isNaN(b)) ? null : { type: "num", min: isNaN(a) ? null : a, max: isNaN(b) ? null : b };
        };
      } else {
        var q = mk(doc, "input"); q.type = "search"; q.placeholder = "buscar"; q.setAttribute("data-role", "q");
        pop.appendChild(q);
        var list = mk(doc, "div", "estudo-pop-l");
        var items = distinctCounts(cells.map(function (r) { return r[col] || ""; })).map(function (vc) {
          var lab = mk(doc, "label"), cb = mk(doc, "input");
          cb.type = "checkbox"; cb.checked = !f || f.set.has(vc[0]);
          lab.appendChild(cb);
          lab.appendChild(doc.createTextNode(" " + (vc[0] === "" ? "(vazio)" : vc[0]) + " (" + vc[1] + ")"));
          list.appendChild(lab);
          return { value: vc[0], cb: cb, lab: lab };
        });
        q.addEventListener("input", function () {
          var s = q.value.toLowerCase();
          items.forEach(function (it) { it.lab.style.display = it.value.toLowerCase().indexOf(s) >= 0 ? "" : "none"; });
        });
        pop.appendChild(list);
        apply = function () {
          var set = new Set(), all = true;
          items.forEach(function (it) { if (it.cb.checked) set.add(it.value); else all = false; });
          filters[col] = all ? null : { type: "text", set: set };   // everything ticked = no filter
        };
      }
      var bar = mk(doc, "div", "estudo-pop-b");
      var clear = mk(doc, "button", null, "Limpar"), ok = mk(doc, "button", null, "Aplicar");
      clear.type = "button"; ok.type = "button";
      clear.addEventListener("click", function () { filters[col] = null; applyFilters(); closePop(doc); });
      ok.addEventListener("click", function () { apply(); applyFilters(); closePop(doc); });
      bar.appendChild(clear); bar.appendChild(ok); pop.appendChild(bar);
      var rect = th.getBoundingClientRect(), win = doc.defaultView;
      pop.style.left = Math.max(0, rect.left + (win ? win.pageXOffset : 0)) + "px";
      pop.style.top = (rect.bottom + (win ? win.pageYOffset : 0)) + "px";
      doc.body.appendChild(pop);
    }

    ths.forEach(function (th, c) {
      th.title = "clique: ordenar · botão direito (ou segurar): filtrar";
      th.addEventListener("click", function () {
        if (th._lp) { th._lp = false; return; }   // the click that follows a long press must not also sort
        closePop(doc);
        sortBy(c, sort.col === c ? -sort.dir : (types[c] === "num" ? -1 : 1));
      });
      th.addEventListener("contextmenu", function (e) { e.preventDefault(); openFilter(c, th); });
      var timer = null;
      th.addEventListener("touchstart", function () {
        timer = setTimeout(function () { th._lp = true; openFilter(c, th); }, LONG_PRESS_MS);
      }, { passive: true });
      ["touchend", "touchmove", "touchcancel"].forEach(function (ev) {
        th.addEventListener(ev, function () { clearTimeout(timer); }, { passive: true });
      });
    });
    return { sortBy: sortBy, openFilter: openFilter };
  }

  function init(doc) {
    var tables = [].slice.call(doc.querySelectorAll("table"));
    tables.forEach(enhance);
    var first = doc.querySelector(".estudo-tw");
    if (first) {
      var tip = mk(doc, "p", "estudo-dica",
        "Tabelas: clique no nome da coluna para ordenar; botão direito (ou segurar no celular) abre o filtro daquela coluna.");
      first.parentNode.insertBefore(tip, first);
    }
    doc.addEventListener("keydown", function (e) { if (e.key === "Escape") closePop(doc); });
    doc.addEventListener("mousedown", function (e) {
      var p = doc.querySelector(".estudo-pop");
      // a press on a column name is handled by that header (it may be opening ITS filter), so it is not "outside"
      if (p && !p.contains(e.target) && !(e.target.closest && e.target.closest("th"))) closePop(doc);
    }, true);
  }

  var api = { parseNum: parseNum, colType: colType, compareCells: compareCells, matches: matches, distinctCounts: distinctCounts, enhance: enhance, init: init };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof document !== "undefined" && document.querySelectorAll) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { init(document); });
    else init(document);
  }
  root.EstudoTabelas = api;
})(typeof window !== "undefined" ? window : this);
