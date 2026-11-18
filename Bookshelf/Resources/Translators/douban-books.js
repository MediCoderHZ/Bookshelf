/*
{
  "translatorID": "douban-books",
  "label": "豆瓣图书",
  "creator": "Bookshelf",
  "version": "1.3.0",
  "priority": 100,
  "targetDescription": "book.douban.com 图书页面与 www.douban.com/search 图书搜索",
  "search": "https://www.douban.com/search?cat=1001&q={query}",
  "targets": [
    {"hosts":["book.douban.com"], "path":"^/(subject/[0-9]+/?)?$", "trailingSlash":true},
    {"hosts":["www.douban.com"], "path":"^/search$", "requireQuery":{"cat":"1001"}, "keepQuery":["q","cat"]}
  ]
}
*/

function detectWeb(doc, url) {
  if (/安全验证|异常请求|访问受限|禁止访问|登录豆瓣|验证码/.test(doc.text("//title")) ||
      doc.first("//*[@id='captcha_image' or @id='captcha' or @name='captcha-solution']")) {
    throw "accessRestricted";
  }
  if (url.host === "www.douban.com") {
    return doc.first("//*[contains(concat(' ', normalize-space(@class), ' '), ' search-result ')]") ? "multiple" : null;
  }
  if (url.path === "/") return doc.first("//a[contains(@href, '/subject/')]") ? "multiple" : null;
  return doc.first("//*[@id='info']") && doc.first("//h1") ? "book" : null;
}

function doSearch(doc, url) {
  if (detectWeb(doc, url) !== "multiple") throw "noBook";
  const rows = doc.nodes("//*[contains(concat(' ', normalize-space(@class), ' '), ' result ')]");
  const results = [], seen = new Set();
  for (const row of rows) {
    const anchor = doc.first(".//h3/a[@href]", row);
    let link = resolveURL(doc.attr(anchor, "href"), url.href);
    if (link?.host === "www.douban.com" && /^\/link2\/?$/.test(link.path)) {
      link = resolveURL(link.query.url, "");
    }
    const detail = canonicalLink(link?.href, url.href);
    const title = doc.value(anchor);
    if (!title || detail?.host !== "book.douban.com" || !detail.path.startsWith("/subject/") || seen.has(detail.href)) continue;
    seen.add(detail.href);
    results.push({ title, url: detail.href, summary: doc.text(".//*[contains(concat(' ', normalize-space(@class), ' '), ' subject-cast ')]", row) });
    if (results.length === 20) break;
  }
  return results;
}

function doWeb(doc, url, kind) {
  if (kind === "multiple") {
    if (url.host === "www.douban.com") return doSearch(doc, url);
    return bookLinks(doc, url, "//a[@href]", link => link.host === "book.douban.com" && link.path.startsWith("/subject/") && link.href);
  }
  const info = doc.first("//*[@id='info']");
  const title = doc.text("//h1//*[@property='v:itemreviewed']") || doc.text("//h1");
  const fields = Object.create(null);
  for (const line of doc.lines(info)) {
    const entry = line.match(/^([^:：]+)[:：](.+)$/);
    if (entry && entry[2].trim()) fields[entry[1].trim()] = entry[2].trim();
  }
  if (!title || !(fields["作者"] || fields["出版社"] || fields.ISBN)) throw "noBook";

  const people = value => (value || "").split(/[/／、]/).map(name => name.trim()).filter(Boolean);
  const isbn = normalizeISBN(fields.ISBN || doc.text("//meta[@property='book:isbn']/@content"));
  const intros = doc.nodes("//*[@id='link-report']//*[contains(concat(' ', normalize-space(@class), ' '), ' intro ')]");
  const description = intros.map(node => doc.lines(node).join("\n\n")).sort((a, b) => b.length - a.length)[0];
  const pages = Number(fields["页数"]?.match(/^[0-9]+/)?.[0]);
  return record({
    id: "douban:" + url.path, title, subtitle: fields["副标题"], authors: people(fields["作者"]),
    publisher: fields["出版社"], publicationDate: fields["出版年"] || fields["出版日期"],
    isbn10: isbn?.length === 10 ? isbn : null, isbn13: isbn?.length === 13 ? isbn : null,
    pageCount: Number.isSafeInteger(pages) && pages > 0 ? pages : null,
    translators: people(fields["译者"]), originalTitle: fields["原作名"], bookDescription: description || null
  });
}
