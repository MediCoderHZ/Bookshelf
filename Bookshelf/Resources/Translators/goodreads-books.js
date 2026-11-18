/*
{
  "translatorID": "goodreads-books",
  "label": "Goodreads",
  "creator": "Bookshelf",
  "version": "1.2.0",
  "priority": 100,
  "targetDescription": "goodreads.com 图书详情、首页、搜索、公开图书列表与书架分类页",
  "search": "https://www.goodreads.com/search?q={query}&search_type=books",
  "targets": [
    {"hosts":["www.goodreads.com","goodreads.com"], "path":"^/(book/show/[0-9]+([.-][^/]+)?/?)?$"},
    {"hosts":["www.goodreads.com","goodreads.com"], "path":"^/(search(/index)?|list/show/[0-9]+([.-][^/]+)?/?|shelf/show/[^/]+/?)$", "keepQuery":["q","search_type","page"]}
  ]
}
*/

function bookID(link) {
  return link?.host === "www.goodreads.com" && link.path.match(/^\/book\/show\/([0-9]+)/)?.[1];
}

function pageEdition(doc, id) {
  const cache = parseJSON(doc.raw(doc.first("//script[@id='__NEXT_DATA__']")))?.props?.pageProps?.apolloState || {};
  const books = Object.entries(cache).filter(([key, book]) => key.startsWith("Book:") && typeof book?.title === "string");
  const book = books.find(([, book]) => String(book.legacyId) === id)?.[1];
  if (!book && books.length) throw "editionMismatch";
  return {cache, book};
}

function structuredBook(doc, id) {
  const books = [];
  function collect(value) {
    if (Array.isArray(value)) return value.forEach(collect);
    if (!value || typeof value !== "object") return;
    if ([value["@type"]].flat().some(type => ["Book", "https://schema.org/Book", "http://schema.org/Book"].includes(type))) books.push(value);
    if (value["@graph"]) collect(value["@graph"]);
  }
  for (const node of doc.nodes("//script[@type='application/ld+json']")) collect(parseJSON(doc.raw(node)));
  return books.find(book => [book.url, book["@id"]].some(link => bookID(canonicalLink(link, "")) === id)) ||
    (books.length === 1 && !books[0].url && !books[0]["@id"] ? books[0] : null);
}

function candidates(doc, url) {
  return bookLinks(doc, url, "//a[contains(@href, '/book/show/')]", bookID);
}

function checkAccess(doc) {
  if (/javascript is disabled|just a moment|access denied|robot check/i.test(doc.text("//head/title")) ||
      /javascript is disabled/i.test(doc.text("//h1")) ||
      doc.first("//*[@id='challenge-form' or @id='captcha' or @id='captcha-container']")) throw "accessRestricted";
}

const titlePath = "//h1[@data-testid='bookTitle' or @id='bookTitle']";
function detectWeb(doc, url) {
  checkAccess(doc);
  const id = bookID(url);
  if (!id) return candidates(doc, url).length ? "multiple" : null;
  return pageEdition(doc, id).book || structuredBook(doc, id) || doc.first(titlePath) ? "book" : null;
}

function doSearch(doc, url) {
  checkAccess(doc);
  if (!doc.first("//input[@id='search_query'] | //form[@action='/search']")) throw "noBook";
  const anchorPath = ".//a[contains(concat(' ', normalize-space(@class), ' '), ' bookTitle ')]";
  const seen = new Set(), results = [];
  for (const row of doc.nodes("//tr[" + anchorPath + "]")) {
    const anchor = doc.first(anchorPath, row);
    const link = canonicalLink(doc.attr(anchor, "href"), url.href), id = bookID(link);
    const title = doc.value(anchor);
    if (!id || !title || seen.has(id)) continue;
    seen.add(id);
    const authors = doc.nodes(".//a[contains(concat(' ', normalize-space(@class), ' '), ' authorName ')]", row).map(doc.value).filter(Boolean);
    results.push({ title, url: link.href, summary: authors.length ? creditLine(authors.join("、")) : null });
    if (results.length === 20) break;
  }
  return results;
}

function doWeb(doc, url, kind) {
  if (kind === "multiple") return candidates(doc, url);
  const id = bookID(url);
  const {cache, book} = pageEdition(doc, id);
  const ld = structuredBook(doc, id) || {};
  const title = clean(book?.title) || clean(ld.name) || doc.text(titlePath);
  if (!id || !title) throw "noBook";
  const names = value => [value || []].flat().map(person => clean(person?.name || person)).filter(Boolean);
  let authors = [], translators = [];
  if (book) {
    for (const edge of [book.primaryContributorEdge, ...(Array.isArray(book.secondaryContributorEdges) ? book.secondaryContributorEdges : [])]) {
      const ref = edge?.node?.__ref;
      const name = typeof ref === "string" && ref.startsWith("Contributor:") && clean(cache[ref]?.name);
      if (!name) continue;
      switch (String(edge.role).toLowerCase()) {
        case "author": authors.push(name); break;
        case "translator": case "translation": translators.push(name); break;
      }
    }
  } else {
    authors = names(ld.author);
    translators = names(ld.translator);
    if (!authors.length && !Object.keys(ld).length) {
      authors = doc.nodes("//*[@id='bookAuthors']//*[@itemprop='author']//*[@itemprop='name']").map(doc.value).filter(Boolean);
    }
  }
  // Only Book.details describes the selected edition. Work supplies its original title.
  const details = book?.details || {};
  const isbn = normalizeISBN(book ? details.isbn : ld.isbn);
  const isbn13 = normalizeISBN(book ? details.isbn13 ?? details.isbn : ld.isbn);
  const time = details.publicationTime;
  const date = typeof time === "number" && Math.abs(time) < 253402214400000 ? new Date(time).toISOString().slice(0, 10) : null;
  const pages = Number(book ? details.numPages : ld.numberOfPages);
  const language = clean(book ? details.language?.name : ld.inLanguage);
  const codes = {english:"en", chinese:"zh", french:"fr", german:"de", spanish:"es", japanese:"ja", korean:"ko",
    italian:"it", portuguese:"pt", russian:"ru"};
  const work = book?.work?.__ref;
  return record({
    id: "goodreads:" + id, title, authors: [...new Set(authors)], translators: [...new Set(translators)],
    isbn10: isbn?.length === 10 ? isbn : null, isbn13: isbn13?.length === 13 ? isbn13 : null,
    publisher: book ? clean(details.publisher) : names(ld.publisher)[0], publicationDate: book ? date : clean(ld.datePublished),
    pageCount: Number.isSafeInteger(pages) && pages > 0 ? pages : null,
    languageCode: language ? (Object.hasOwn(codes, language.toLowerCase()) ? codes[language.toLowerCase()] :
      (/^[a-z]{2,3}(-[A-Za-z]{2,8})?$/.test(language) ? language : null)) : null,
    originalTitle: typeof work === "string" && work.startsWith("Work:") ? clean(cache[work]?.details?.originalTitle) : null,
    bookDescription: plainHTML(clean(book?.description) || clean(ld.description) || "") ||
      doc.lines(doc.first("//*[@data-testid='description']//*[@data-testid='contentContainer']")).join("\n\n") || null
  });
}
