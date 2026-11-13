// Folio — 使用文档: the contents follow the reading, search narrows them, figures zoom, hotspots name the parts of a window.
(function () {
  var doc = document.querySelector(".doc");
  var toc = document.querySelector(".toc");
  var links = Array.prototype.slice.call(toc.querySelectorAll("a[href^='#']"));
  var targets = links.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); });

  // Anchors to copy beside headings.
  Array.prototype.forEach.call(doc.querySelectorAll("h2[id], h3[id]"), function (h) {
    var a = document.createElement("a");
    a.className = "anchor";
    a.href = "#" + h.id;
    a.textContent = "#";
    a.setAttribute("aria-label", "本节链接");
    h.appendChild(a);
  });

  // The section being read, marked in the contents.
  function mark() {
    var y = window.scrollY + 120, current = 0;
    for (var i = 0; i < targets.length; i++) if (targets[i] && targets[i].offsetTop <= y) current = i;
    links.forEach(function (a, i) { a.classList.toggle("on", i === current); });
    var on = links[current];
    if (on && !document.body.classList.contains("toc-open")) {
      var top = on.offsetTop - toc.clientHeight / 2;
      if (Math.abs(toc.scrollTop - top) > toc.clientHeight / 3) toc.scrollTop = top;
    }
  }
  var pending = false;
  window.addEventListener("scroll", function () {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; mark(); });
  }, { passive: true });
  mark();

  // Search: sections whose text has every word stay, with their entries in the contents.
  var search = toc.querySelector(".search");
  var empty = toc.querySelector(".empty");
  var sections = Array.prototype.slice.call(doc.querySelectorAll("section[id]"));
  search.addEventListener("input", function () {
    var words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    var shown = 0;
    sections.forEach(function (s) {
      var text = s.textContent.toLowerCase();
      var hit = words.every(function (w) { return text.indexOf(w) >= 0; });
      s.classList.toggle("hidden-by-search", !hit);
      var entry = toc.querySelector("a[href='#" + s.id + "']");
      if (entry) entry.parentElement.classList.toggle("hidden-by-search", !hit);
      if (hit) shown++;
    });
    empty.style.display = shown ? "none" : "block";
    doc.querySelector("header.intro").classList.toggle("hidden-by-search", words.length > 0);
  });

  // Contents on small screens.
  var toggle = document.querySelector(".toc-toggle");
  toggle.addEventListener("click", function () { document.body.classList.toggle("toc-open"); });
  links.forEach(function (a) { a.addEventListener("click", function () { document.body.classList.remove("toc-open"); }); });

  // Figures: a click shows them large.
  var zoom = document.createElement("div");
  zoom.className = "zoom";
  zoom.innerHTML = "<img alt=''>";
  document.body.appendChild(zoom);
  doc.addEventListener("click", function (e) {
    var img = e.target.closest("figure img");
    if (!img) return;
    zoom.querySelector("img").src = img.currentSrc || img.src;
    zoom.classList.add("on");
  });
  zoom.addEventListener("click", function () { zoom.classList.remove("on"); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") zoom.classList.remove("on"); });

  // Hotspots: a number on the figure and its line in the legend light up together.
  Array.prototype.forEach.call(doc.querySelectorAll("[data-tour]"), function (tour) {
    var legend = document.getElementById(tour.getAttribute("data-tour"));
    var spots = tour.querySelectorAll(".hotspot");
    function light(n) {
      Array.prototype.forEach.call(spots, function (s) { s.classList.toggle("on", s.textContent === n); });
      Array.prototype.forEach.call(legend.children, function (li, i) { li.classList.toggle("on", String(i + 1) === n); });
    }
    Array.prototype.forEach.call(spots, function (s) {
      s.addEventListener("mouseenter", function () { light(s.textContent); });
      s.addEventListener("click", function (e) { e.stopPropagation(); light(s.textContent); legend.children[Number(s.textContent) - 1].scrollIntoView({ block: "nearest", behavior: "smooth" }); });
    });
    Array.prototype.forEach.call(legend.children, function (li, i) {
      li.addEventListener("mouseenter", function () { light(String(i + 1)); });
    });
  });
})();
