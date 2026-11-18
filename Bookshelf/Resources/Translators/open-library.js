/*
{
  "translatorID": "open-library",
  "label": "Open Library",
  "creator": "Bookshelf",
  "version": "1.1.0",
  "priority": 200,
  "targetDescription": "书名或 ISBN 检索 · openlibrary.org",
  "search": "https://openlibrary.org/search?q={query}",
  "targets": []
}
*/

function requestURL(query) {
  const text = encodeURIComponent(query.text);
  if (query.kind === "isbn") return "https://openlibrary.org/api/books?bibkeys=ISBN:" + text + "&jscmd=data&format=json";
  const fields = "key,title,subtitle,author_name,first_publish_year,publisher,publish_date,isbn,number_of_pages_median,language";
  return "https://openlibrary.org/search.json?title=" + text + "&fields=" + fields + "&lang=zh&limit=15";
}

function doSearch(query, response) {
  const data = JSON.parse(response);
  if (!data || typeof data !== "object" || Array.isArray(data)) throw "invalidResponse";
  if (query.kind === "isbn") {
    const requested = normalizeISBN(query.text);
    return Object.entries(data).sort(([a], [b]) => a.localeCompare(b)).flatMap(([id, entry]) => {
      const title = clean(entry?.title);
      if (!title) return [];
      const identifiers = entry.identifiers || {};
      return [record({
        id, title, subtitle: clean(entry.subtitle), authors: (entry.authors || []).map(author => author.name),
        publisher: clean(entry.publishers?.[0]?.name), publicationDate: clean(entry.publish_date),
        isbn10: normalizeISBN(identifiers.isbn_10?.[0]) || (requested?.length === 10 ? requested : null),
        isbn13: normalizeISBN(identifiers.isbn_13?.[0]) || (requested?.length === 13 ? requested : null),
        pageCount: entry.number_of_pages
      })];
    });
  }
  if (!Array.isArray(data.docs)) throw "invalidResponse";
  const codes = {chi:"zh-Hans", zho:"zh-Hans", eng:"en", jpn:"ja", kor:"ko", fre:"fr", fra:"fr", ger:"de", deu:"de", spa:"es"};
  return data.docs.flatMap(entry => {
    const title = clean(entry?.title);
    if (!title) return [];
    const authors = entry.author_name || [], isbns = (entry.isbn || []).map(normalizeISBN).filter(Boolean);
    const language = clean(entry.language?.[0]);
    return [record({
      id: entry.key ?? title + "-" + (authors[0] || ""), title, authors, subtitle: clean(entry.subtitle),
      publisher: clean(entry.publisher?.[0]), publicationDate: clean(entry.publish_date?.[0]) || entry.first_publish_year?.toString(),
      isbn10: isbns.find(isbn => isbn.length === 10), isbn13: isbns.find(isbn => isbn.length === 13),
      pageCount: entry.number_of_pages_median, languageCode: language && Object.hasOwn(codes, language.toLowerCase()) ? codes[language.toLowerCase()] : language
    })];
  });
}
