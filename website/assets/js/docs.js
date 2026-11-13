// Folio 使用指南: the index follows the reading, searches the chapters, and opens as a menu on small screens.
(function () {
  // ── Index: current chapter, search, menu on small screens ──
  var index = document.querySelector(".index");
  var links = Array.prototype.slice.call(index.querySelectorAll("a[href^='#']"));
  var chapters = links.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); });
  function mark() {
    var y = window.scrollY + 140, current = -1;
    chapters.forEach(function (c, i) { if (c && !c.classList.contains("hidden") && c.offsetTop <= y) current = i; });
    links.forEach(function (a, i) { a.classList.toggle("on", i === current); });
  }
  var queued = false;
  window.addEventListener("scroll", function () {
    if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; mark(); }); }
  }, { passive: true });
  mark();

  var input = index.querySelector("input");
  var none = index.querySelector(".none");
  input.addEventListener("input", function () {
    var words = input.value.trim().toLowerCase().split(/\s+/).filter(Boolean), shown = 0;
    chapters.forEach(function (c, i) {
      var hit = words.every(function (w) { return c.textContent.toLowerCase().indexOf(w) >= 0; });
      c.classList.toggle("hidden", !hit);
      links[i].parentElement.classList.toggle("hidden", !hit);
      if (hit) shown++;
    });
    document.querySelector(".hero").classList.toggle("hidden", words.length > 0);
    none.style.display = shown ? "none" : "block";
  });

  var menu = document.querySelector(".menu-button");
  menu.addEventListener("click", function () {
    var open = document.body.classList.toggle("index-open");
    menu.setAttribute("aria-expanded", open);
  });
  links.forEach(function (a) { a.addEventListener("click", function () { document.body.classList.remove("index-open"); }); });
})();
