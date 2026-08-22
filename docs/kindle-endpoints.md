# Kindle private endpoints used by Flyleaf

Flyleaf talks to the same endpoints the Kindle Cloud Reader (read.amazon.com) uses in a browser. Read-only, user-credentialed, low volume. No book content, DRM, or renderer calls, ever.

## Auth model

1. User signs into `https://read.amazon.<region>` in an embedded WKWebView. WebKit persists the session cookies (`ubid-*`, `at-*`, `x-*`, `session-id`) in the default website data store, which is the single source of truth; Flyleaf reads them fresh before each request batch.
2. Device registration handshake, the same one the web reader performs:

```
GET /service/web/register/getDeviceToken?serialNumber=A2CTZ977SKFQZY&deviceType=A2CTZ977SKFQZY
-> { "deviceSessionToken": "..." }
```

`A2CTZ977SKFQZY` is the Kindle Cloud Reader device type. The returned token is sent as `x-adp-session-token` on subsequent calls, with `x-amzn-sessionid` set from the `session-id` cookie.

## Position polling (the whole loop)

```
GET /kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50[&paginationToken=N]
-> { "itemsList": [ { asin, title, authors, productUrl, percentageRead, resourceType, originType, webReaderUrl } ], "paginationToken": "50" }
```

One request per poll. `sortType=recency` puts the most recently opened book first (auto book detection) and `percentageRead` is the Whispersync furthest-position percent (auto position). Cadence: 45 to 60 seconds while a session is active, 10 minutes idle, hourly overnight, all with jitter.

## Per-book detail (once per book adoption, not per poll)

```
GET /service/mobile/reader/startReading?asin=<ASIN>&clientVersion=20000100
-> { kindleSessionId, metadataUrl, srl, isSample, isOwned,
     lastPageReadData: { deviceName, position, syncTime }, ... }
```

Gives the syncing device's name ("synced 2m ago from Oasis"), the raw furthest position, and `metadataUrl`: a CDN JSONP document (`loadMetadata({...})`) containing `startPosition`, `endPosition`, `publisher`, `releaseDate`, and for many books a nav `toc` with positions. When the TOC is present, chapter boundaries are exact: `percent = (position - startPosition) / (endPosition - startPosition)`. This is delivery metadata, not book content.

## Fallbacks and politeness

- Requests go out via URLSession with Safari's user agent (captured from the login webview for coherence). Amazon has TLS-fingerprinted plain HTTP clients in the past (Node clients need a proxy for this reason); Apple's network stack presents a Safari-family fingerprint, and if a bot challenge is ever detected anyway, the client switches to a hidden WKWebView issuing same-origin `fetch()` calls, which is indistinguishable from the web reader.
- Redirects off the reader host are treated as session expiry and surface as a one-click re-auth, never a retry loop.
- Rate: one library call per poll tick. No book downloads, no renderer, no annotation endpoints.

## Sources

- [transitive-bullshit/kindle-api](https://github.com/transitive-bullshit/kindle-api), TypeScript client this integration mirrors (endpoints, headers, device token flow, progress calculation).
- [Xetera/kindle-api](https://github.com/Xetera/kindle-api), original library; documents the required cookies and Amazon's TLS fingerprinting of non-browser clients.
- [Amazon Kindle Export gist (jkubecki)](https://gist.github.com/jkubecki/d61d3e953ed5c8379075b5ddd8a95f22), community discovery of the library search endpoint shapes.
- [Kindle Web Reader pages writeup (noh.am)](https://noh.am/en/posts/kindle-web-reader-pages/), `loadMetadata` JSONP fields.
