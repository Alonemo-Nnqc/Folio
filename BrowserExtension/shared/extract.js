// Folio - reads the bibliographic metadata of the current page (WEB-02).
// Injected only when the user clicks the toolbar button; the last expression is the result.
// Sources, best first: site rules, Highwire citation_* / Dublin Core / PRISM / bepress / eprints meta tags,
// JSON-LD, COinS, identifiers in the URL and on the page. A page that lists several works (search results,
// arXiv listings, tables of contents) also returns `candidates` for batch saving.
(() => {
  const clean = (text) => (text || "").replace(/\s+/g, " ").trim();
  const absolute = (href) => {
    try { return new URL(href, location.href).href; } catch { return ""; }
  };

  // Meta tags by lowercased name / property, in document order.
  const metaIndex = new Map();
  for (const tag of document.querySelectorAll("meta[name], meta[property]")) {
    const key = (tag.getAttribute("name") || tag.getAttribute("property") || "").toLowerCase();
    const value = clean(tag.getAttribute("content"));
    if (!key || !value) continue;
    if (!metaIndex.has(key)) metaIndex.set(key, []);
    metaIndex.get(key).push(value);
  }
  // All values of the first name (in priority order) that has any.
  const metas = (...names) => {
    for (const name of names) {
      const values = metaIndex.get(name.toLowerCase());
      if (values && values.length) return values;
    }
    return [];
  };
  const meta = (...names) => metas(...names)[0] || "";
  // Every value of every listed name (for identifiers spread over several tags).
  const allMetas = (...names) => names.flatMap((name) => metaIndex.get(name.toLowerCase()) || []);

  const doiPattern = /\b(10\.\d{4,9}\/[^\s"'<>\uFF0C\u3002\uFF1B\u3001]+)/i;
  const cleanDOI = (doi) => decodeURIComponent(doi).replace(/[.,;:)\]}>]+$/, "").replace(/\/(full|abstract|pdf|epdf|html)$/i, "");
  const findDOI = (...values) => {
    for (const value of values) {
      const match = String(value || "").match(doiPattern);
      if (match) return cleanDOI(match[1]);
    }
    return "";
  };
  const arxivPattern = /arxiv\.org\/(?:abs|pdf|html)\/((?:\d{4}\.\d{4,5})|(?:[a-z-]+(?:\.[A-Z]{2})?\/\d{7}))(v\d+)?/i;

  const contentType = (document.contentType || "").toLowerCase();
  const isPDF = contentType === "application/pdf" || /\.pdf($|[?#])/i.test(location.pathname)
    || Boolean(document.querySelector('embed[type="application/pdf"]') && document.body && document.body.children.length <= 2);
  const result = { version: 2, url: location.href, pageTitle: clean(document.title), isPDF };

  if (isPDF) {
    result.pdfUrl = location.href;
    result.title = clean(document.title).replace(/\.pdf$/i, "") || decodeURIComponent(location.pathname.split("/").pop() || "");
    const arxiv = location.href.match(arxivPattern);
    if (arxiv) result.arxiv = arxiv[1];
    const doi = findDOI(location.href);
    if (doi) result.doi = doi;
    return result;
  }

  // ---- Highwire Press (Google Scholar's standard), Dublin Core, PRISM, bepress, eprints
  result.title = meta("citation_title", "dc.title", "prism.title", "bepress_citation_title", "eprints.title");
  let authors = metas("citation_author", "bepress_citation_author", "eprints.creators_name");
  if (!authors.length) authors = metas("citation_authors", "dc.creator", "dcterms.creator").flatMap((a) => a.split(/\s*;\s*/));
  result.authors = authors.map(clean).filter(Boolean);
  result.date = meta("citation_publication_date", "citation_date", "citation_cover_date", "citation_online_date",
    "prism.publicationdate", "prism.coverdate", "dc.date", "dcterms.issued", "dcterms.date", "eprints.date", "article:published_time");
  result.venue = meta("citation_journal_title", "citation_conference_title", "citation_inbook_title", "citation_book_title",
    "prism.publicationname", "bepress_citation_journal_title", "eprints.publication", "citation_dissertation_institution",
    "citation_technical_report_institution");
  result.volume = meta("citation_volume", "prism.volume", "eprints.volume");
  result.issue = meta("citation_issue", "prism.number", "prism.issueidentifier", "eprints.number");
  const firstPage = meta("citation_firstpage", "prism.startingpage", "bepress_citation_firstpage");
  const lastPage = meta("citation_lastpage", "prism.endingpage", "bepress_citation_lastpage");
  result.pages = firstPage && lastPage ? `${firstPage}-${lastPage}` : firstPage || meta("eprints.pagerange");
  result.publisher = meta("citation_publisher", "dc.publisher", "dcterms.publisher", "prism.publisher", "eprints.publisher");
  result.isbn = meta("citation_isbn", "prism.isbn");
  result.abstract = meta("citation_abstract", "dc.description", "dcterms.abstract", "prism.abstract", "eprints.abstract");
  // Generic page descriptions ("Abstract page for arXiv paper ...") are not abstracts.
  if (!result.abstract) {
    const description = meta("description", "og:description");
    if (description.length > 200) result.abstract = description;
  }
  result.doi = findDOI(...allMetas("citation_doi", "prism.doi", "bepress_citation_doi", "dc.identifier", "dcterms.identifier",
    "eprints.id_number", "citation_id"));
  result.arxiv = meta("citation_arxiv_id");
  const arxivPage = location.href.match(arxivPattern);
  if (arxivPage) result.arxiv = arxivPage[1];
  const pdf = meta("citation_pdf_url", "bepress_citation_pdf_url", "eprints.document_url");
  if (pdf) result.pdfUrl = absolute(pdf);
  if (meta("citation_conference_title")) result.type = "conferencePaper";
  else if (meta("citation_dissertation_institution")) result.type = "thesis";
  else if (meta("citation_technical_report_institution")) result.type = "report";

  // ---- Site rules for pages without (complete) scholarly meta tags
  const host = location.hostname.replace(/^www\./, "");

  // IEEE Xplore keeps its metadata in a script variable.
  if (/(^|\.)ieeexplore\.ieee\.org$/.test(host) && (!result.title || !result.authors.length)) {
    const source = [...document.scripts].map((s) => s.textContent).find((t) => t && t.includes("xplGlobal.document.metadata"));
    const match = source && source.match(/xplGlobal\.document\.metadata\s*=\s*(\{[\s\S]*?\});\s*\n/);
    let data = null;
    try { data = match && JSON.parse(match[1]); } catch { data = null; }
    if (data) {
      result.title = clean(data.formulaStrippedArticleTitle || data.title);
      result.authors = (data.authors || []).map((a) => (a.lastName ? `${a.lastName}, ${a.firstName || ""}` : a.name || "").trim()).filter(Boolean);
      result.date = clean(data.publicationDate || data.publicationYear);
      result.venue = clean(data.publicationTitle);
      result.volume = clean(data.volume);
      result.issue = clean(data.issue);
      result.pages = data.startPage && data.endPage ? `${data.startPage}-${data.endPage}` : clean(data.startPage);
      result.publisher = clean(data.publisher) || "IEEE";
      result.doi = data.doi || result.doi;
      result.abstract = clean(data.abstract);
      if (data.pdfPath) result.pdfUrl = absolute(data.pdfPath);
      else if (data.articleNumber) result.pdfUrl = `https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=${data.articleNumber}`;
      result.type = data.isConference ? "conferencePaper" : data.isBook || data.isChapter ? "bookChapter" : "journalArticle";
    }
  }

  // ScienceDirect: the DOI link in the article header; Folio looks up the rest.
  if (/(^|\.)sciencedirect\.com$/.test(host)) {
    const doiLink = document.querySelector("a.doi, a.anchor.doi, .article-identifier-links a[href*='doi.org']");
    result.doi = result.doi || findDOI(doiLink && (doiLink.href || doiLink.textContent));
    result.title = result.title || clean(document.querySelector(".title-text, h1")?.textContent);
    if (!result.authors.length) {
      result.authors = [...document.querySelectorAll(".author-group .react-xocs-alternative-link, .author-group button .given-name")]
        .map((node) => clean(node.closest("button, a")?.textContent || node.textContent)).filter(Boolean);
    }
    const pdfLink = document.querySelector("a.pdf-download-btn-link, a[aria-label*='PDF'][href*='pdfft'], a[href*='/pdfft']");
    if (!result.pdfUrl && pdfLink) result.pdfUrl = absolute(pdfLink.getAttribute("href"));
  }

  // OpenReview forum pages: the PDF sits at /pdf?id=...
  if (/(^|\.)openreview\.net$/.test(host) && !result.pdfUrl) {
    const id = new URLSearchParams(location.search).get("id");
    if (id) result.pdfUrl = `https://openreview.net/pdf?id=${id}`;
  }

  // ---- JSON-LD (schema.org ScholarlyArticle and friends)
  if (!result.title || !result.authors.length || !result.doi) {
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      let data;
      try { data = JSON.parse(script.textContent); } catch { continue; }
      const nodes = [].concat(data).flatMap((d) => [].concat(d && d["@graph"] ? d["@graph"] : d));
      const article = nodes.find((n) => n && /ScholarlyArticle|Article|Book|Thesis|Report|Chapter|Dataset/.test([].concat(n["@type"]).join(" ")));
      if (!article) continue;
      result.title = result.title || clean(article.headline || article.name);
      if (!result.authors.length) {
        result.authors = [].concat(article.author || []).map((a) => clean(typeof a === "string" ? a : a.name || [a.familyName, a.givenName].filter(Boolean).join(", "))).filter(Boolean);
      }
      result.date = result.date || clean(article.datePublished);
      result.venue = result.venue || clean(article.isPartOf && (article.isPartOf.name || (article.isPartOf.isPartOf || {}).name));
      result.doi = result.doi || findDOI(JSON.stringify(article.identifier || ""), article.sameAs, article["@id"], article.url);
      result.abstract = result.abstract || clean(article.description).slice(0, 5000);
      if (!result.type && /Dataset/.test([].concat(article["@type"]).join(" "))) result.type = "dataset";
      break;
    }
  }

  // ---- COinS (OpenURL ContextObjects in span.Z3988): library catalogues, Wikipedia, many repositories
  const coins = [...document.querySelectorAll("span.Z3988[title]")];
  if (coins.length === 1 && (!result.title || !result.doi)) {
    const params = new URLSearchParams(coins[0].getAttribute("title"));
    const get = (key) => clean(params.get(key));
    result.title = result.title || get("rft.atitle") || get("rft.btitle") || get("rft.title");
    if (!result.authors.length) {
      const names = params.getAll("rft.au").map(clean).filter(Boolean);
      if (!names.length && get("rft.aulast")) names.push([get("rft.aulast"), get("rft.aufirst")].filter(Boolean).join(", "));
      result.authors = names;
    }
    result.date = result.date || get("rft.date");
    result.venue = result.venue || get("rft.jtitle") || get("rft.stitle");
    result.volume = result.volume || get("rft.volume");
    result.issue = result.issue || get("rft.issue");
    result.pages = result.pages || get("rft.pages") || [get("rft.spage"), get("rft.epage")].filter(Boolean).join("-");
    result.isbn = result.isbn || get("rft.isbn");
    result.doi = result.doi || findDOI(...params.getAll("rft_id"));
    const genre = get("rft.genre");
    if (!result.type) result.type = { article: "journalArticle", proceeding: "conferencePaper", conference: "conferencePaper", book: "book", bookitem: "bookChapter", report: "report" }[genre] || "";
  }

  // ---- Identifiers in the URL and on the page
  if (!result.doi && (/doi\.org\//i.test(location.href) || /\/doi\/(abs\/|full\/|pdf\/|epdf\/)?10\./i.test(location.pathname))) {
    result.doi = findDOI(location.href);
  }
  // Where the reference list begins: DOIs after it belong to cited works, not to this page.
  const referencesHeading = [...document.querySelectorAll("h1, h2, h3, h4, section > header, .section-title")]
    .find((node) => /^(\d+\.?\s*)?(references|bibliography|literature cited|works cited|\u53C2\u8003\u6587\u732E|\u5F15\u7528\u6587\u732E)\s*$/i.test(clean(node.textContent)));
  const beforeReferences = (node) => !referencesHeading
    || Boolean(referencesHeading.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_PRECEDING);
  if (!result.doi) {
    // A DOI the page labels as its own, or the only DOI linked above the references.
    const labelled = document.querySelector("[data-doi], a.doi, .doi a, #doi a, .article-doi a, .citation-doi a");
    result.doi = findDOI(labelled && (labelled.getAttribute("data-doi") || labelled.href || labelled.textContent));
    if (!result.doi) {
      const linked = [...new Set([...document.querySelectorAll("a[href*='doi.org/10.']")].filter(beforeReferences).map((a) => findDOI(a.href)).filter(Boolean))];
      if (linked.length === 1) result.doi = linked[0];
    }
    if (!result.doi && document.body) {
      const text = document.body.innerText.slice(0, 20000);
      const labelledText = text.match(/\bDOI\s*[:\uFF1A]?\s*(10\.\d{4,9}\/[^\s"'<>\uFF0C\u3002\uFF1B\u3001]+)/i);
      if (labelledText) result.doi = cleanDOI(labelledText[1]);
    }
  }

  // ---- Item type and whether this page is one reference
  if (!result.type) {
    result.type = meta("citation_journal_title") || meta("prism.publicationname") ? "journalArticle"
      : result.arxiv ? "preprint"
      : result.isbn && !result.venue ? "book"
      : result.doi ? "journalArticle" : "";
  }
  // A page is a reference when it names a work (scholarly tags, a DOI or an arXiv ID).
  result.isReference = Boolean((meta("citation_title") || (meta("dc.title") && result.authors.length) || result.doi || result.arxiv
    || coins.length === 1) && (result.title || result.doi || result.arxiv));
  if (!result.title) result.title = clean(document.querySelector("h1")?.textContent) || meta("og:title") || result.pageTitle;

  // ---- Several works on one page (search results, listings, tables of contents)
  if (!result.isReference) {
    const titleOf = (link) => {
      const own = clean(link.textContent);
      if (own.length >= 20 && !/^(https?:|doi:|10\.\d|arxiv:|\[?pdf\]?$)/i.test(own)) return own;
      // arXiv listings: <dt> holds the links, the next <dd> the title.
      const dt = link.closest("dt");
      if (dt && dt.nextElementSibling) {
        const title = dt.nextElementSibling.querySelector(".list-title");
        if (title) return clean(title.textContent.replace(/^Title:\s*/i, ""));
      }
      let box = link.parentElement;
      for (let depth = 0; box && depth < 6; depth += 1, box = box.parentElement) {
        if ((box.textContent || "").length > 4000) break;
        const heading = box.querySelector("h1, h2, h3, h4, h5, .title, [class*='title'], [class*='Title']");
        const text = clean(heading && heading.textContent).replace(/^Title:\s*/i, "");
        if (text.length >= 15 && text.length <= 500) return text;
      }
      return own;
    };
    const seen = new Set();
    const candidates = [];
    for (const link of document.querySelectorAll("a[href]")) {
      const href = link.href || "";
      const arxiv = href.match(arxivPattern);
      const doi = arxiv ? "" : findDOI(/doi\.org\/|\/doi\/|\/article\/10\.|\/chapter\/10\.|\/book\/10\./i.test(href) ? href : "");
      const identifier = arxiv ? arxiv[1] : doi;
      if (!identifier || seen.has(identifier.toLowerCase())) continue;
      seen.add(identifier.toLowerCase());
      candidates.push({ identifier, kind: arxiv ? "arXiv" : "DOI", title: titleOf(link), url: href });
      if (candidates.length >= 100) break;
    }
    if (candidates.length >= 2) result.candidates = candidates;
  }
  return result;
})();
