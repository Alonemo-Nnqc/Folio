// Folio — reads the bibliographic metadata of the current page (WEB-02).
// Injected only when the user clicks the toolbar button; the last expression is the result.
(() => {
  const metas = (names) => {
    const wanted = names.map((n) => n.toLowerCase());
    return [...document.querySelectorAll("meta[name], meta[property]")]
      .filter((m) => wanted.includes((m.getAttribute("name") || m.getAttribute("property") || "").toLowerCase()))
      .map((m) => (m.getAttribute("content") || "").trim())
      .filter(Boolean);
  };
  const meta = (...names) => metas(names)[0] || "";
  const clean = (text) => (text || "").replace(/\s+/g, " ").trim();
  const absolute = (href) => {
    try { return new URL(href, location.href).href; } catch { return ""; }
  };

  const doiPattern = /\b(10\.\d{4,9}\/[^\s"'<>]+)/i;
  const findDOI = (...values) => {
    for (const value of values) {
      const match = (value || "").match(doiPattern);
      if (match) return match[1].replace(/[.,;)\]]+$/, "");
    }
    return "";
  };

  const isPDF = document.contentType === "application/pdf" || /\.pdf($|[?#])/i.test(location.pathname);
  const result = { url: location.href, pageTitle: clean(document.title), isPDF };
  if (isPDF) {
    result.pdfUrl = location.href;
    result.title = clean(document.title).replace(/\.pdf$/i, "");
    const arxivPDF = location.href.match(/arxiv\.org\/pdf\/([\w.\-/]+?)(v\d+)?(\.pdf)?$/i);
    if (arxivPDF) result.arxiv = arxivPDF[1];
    return result;
  }

  // Highwire Press tags (Google Scholar's standard) — most journals, arXiv, CVF, ACL, OpenReview …
  // Scholarly tags only here; og:title and the page title are last resorts (site handlers come first).
  result.title = clean(meta("citation_title", "dc.title", "prism.title"));
  let authors = metas(["citation_author"]);
  if (!authors.length) authors = metas(["dc.creator", "citation_authors"]).flatMap((a) => a.split(/\s*;\s*/));
  result.authors = authors.map(clean).filter(Boolean);
  result.date = clean(meta("citation_publication_date", "citation_date", "citation_online_date", "citation_cover_date",
    "dc.date", "prism.publicationdate", "article:published_time"));
  result.venue = clean(meta("citation_journal_title", "citation_conference_title", "citation_inbook_title",
    "citation_book_title", "prism.publicationname", "citation_dissertation_institution"));
  result.volume = clean(meta("citation_volume", "prism.volume"));
  result.issue = clean(meta("citation_issue", "prism.number"));
  const first = clean(meta("citation_firstpage", "prism.startingpage"));
  const last = clean(meta("citation_lastpage", "prism.endingpage"));
  result.pages = first && last ? `${first}-${last}` : first;
  result.publisher = clean(meta("citation_publisher", "dc.publisher"));
  result.isbn = clean(meta("citation_isbn"));
  result.abstract = clean(meta("citation_abstract", "dc.description", "prism.abstract"));
  // Generic page descriptions ("Abstract page for arXiv paper …") are not abstracts.
  if (!result.abstract) {
    const description = clean(meta("description", "og:description"));
    if (description.length > 200) result.abstract = description;
  }
  result.doi = findDOI(meta("citation_doi"), meta("dc.identifier"), meta("prism.doi"), meta("bepress_citation_doi"),
    location.href.includes("doi.org/") || location.pathname.includes("/doi/") ? location.href : "");
  result.arxiv = clean(meta("citation_arxiv_id"));
  const arxivPage = location.href.match(/arxiv\.org\/abs\/([\w.\-/]+?)(v\d+)?$/i);
  if (arxivPage) result.arxiv = arxivPage[1];
  const pdf = meta("citation_pdf_url");
  if (pdf) result.pdfUrl = absolute(pdf);

  // IEEE Xplore keeps its metadata in a script variable instead of meta tags.
  if (!result.title && /ieeexplore\.ieee\.org$/.test(location.hostname)) {
    const source = [...document.scripts].map((s) => s.textContent).find((t) => t.includes("xplGlobal.document.metadata"));
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
      result.type = data.isConference ? "conferencePaper" : data.isBook || data.isChapter ? "bookChapter" : "journalArticle";
    }
  }

  // JSON-LD (schema.org ScholarlyArticle and friends)
  if (!result.title || !result.authors.length) {
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      let data;
      try { data = JSON.parse(script.textContent); } catch { continue; }
      const nodes = [].concat(data["@graph"] || data);
      const article = nodes.find((n) => /ScholarlyArticle|Article|Book|Thesis|Report|Chapter/.test([].concat(n["@type"]).join(" ")));
      if (!article) continue;
      result.title = result.title || clean(article.headline || article.name);
      if (!result.authors.length) {
        result.authors = [].concat(article.author || []).map((a) => clean(typeof a === "string" ? a : a.name)).filter(Boolean);
      }
      result.date = result.date || clean(article.datePublished);
      result.venue = result.venue || clean(article.isPartOf && (article.isPartOf.name || (article.isPartOf.isPartOf || {}).name));
      result.doi = result.doi || findDOI(JSON.stringify(article.identifier || ""), article.sameAs, article["@id"]);
      result.abstract = result.abstract || clean(article.description);
      break;
    }
  }

  // Item type
  const kind = result.type || (meta("citation_conference_title") ? "conferencePaper"
    : meta("citation_journal_title") || meta("prism.publicationname") ? "journalArticle"
    : result.arxiv ? "preprint"
    : meta("citation_dissertation_institution") ? "thesis"
    : result.isbn && !result.venue ? "book"
    : result.doi ? "journalArticle" : "");
  result.type = kind;
  // A page is a reference when it names a work (citation tags, a DOI or an arXiv ID).
  result.isReference = Boolean((meta("citation_title") || result.doi || result.arxiv || kind) && result.title);
  if (!result.title) result.title = clean(meta("og:title")) || result.pageTitle;
  return result;
})();
