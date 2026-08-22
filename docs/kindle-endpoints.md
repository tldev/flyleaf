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

## Personal documents (Send-to-Kindle): the working path

Emailed books do not appear in the Cloud Reader library API (verified 2026-08-22: `libraryType=PDOCS`/`DOCS` and `resourceType=PDOC` all return HTTP 400; a title search finds nothing), and the web reader cannot open them (`startReading` returns `downloadRestrictionReason: ContentUnsupported`). Cookie auth to the CDE sidecar returns HTTP 200 with an empty body. So there is no cookie-only route to a personal document's position.

Flyleaf follows them anyway, in three steps, all verified end to end against a real account:

1. **List them** (cookie auth): the Manage-Your-Content console.
   - CSRF token from an HTML page under `www.amazon.<tld>/hz/mycd/digital-console/...` (`csrfToken` in the markup).
   - `POST www.amazon.<tld>/hz/mycd/digital-console/ajax`, form body `activity=GetContentOwnershipData&activityInput={...contentType:"KindlePDoc", contentCategoryReference:"pdocs"...}&csrfToken=...` → JSON items with `asin`, `title`, `authors`.

2. **Register this Mac as a device** (once): the OAuth flow real Kindle/Audible apps use.
   - Build a PKCE challenge, load `www.amazon.<tld>/ap/signin?openid.oa2.response_type=code&...&openid.oa2.scope=device_auth_access&openid.oa2.client_id=device:<hex(serial#deviceType)>` in a web view. Because the session is already signed in, Amazon redirects to `/ap/maplanding?openid.oa2.authorization_code=...` with no second login (a hidden view; surfaced only if consent is needed).
   - `POST api.amazon.<tld>/auth/register` with the code, `code_verifier`, and `registration_data` → `response.success.tokens.mac_dms.adp_token` and `device_private_key`.

3. **Read the furthest-read position** (ADP device auth): sign requests as that device and call the CDE.
   - Signature: `x-adp-token`, `x-adp-alg: SHA256withRSA:1.0`, and `x-adp-signature = base64(RSA-SHA256("<METHOD>\n<path>\n<date>\n<body>\n<adp_token>")):<date>`.
   - `GET cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar?type=PDOC&key=<asin>` returns JSON: `payload.records[]` with `type: "kindle.lpr"`, `location` (the furthest-read position), and `creationTime` (when, and `getAnnotations?filter=last_read...` names the device). Example: Apple in China → `location 190065`, last read from "Thomas's 3rd Kindle".

What is not exposed: the document's total position count. The delivery manifest (`kindle-digital-delivery.amazon.com/delivery/manifest/...`) is a GET-only CDN that rejects the request, and `syncMetaData`/`getItems` are empty for a fresh device. So Flyleaf estimates the position scale (assume mid-book, then track the observed maximum) and the chapter control calibrates it exactly with one tap (`impliedMax = position / chapterStartFraction`). Percent for personal documents is therefore approximate until it self-calibrates.

Registration adds a device named "Flyleaf on Mac" to the account; it is removable in Settings (deregister) or at amazon.com. Whispersync-for-Documents must be enabled on the account (it is by default) for positions to sync.

Dev probes: `flyleaf://diag?q=<term>` (enumerate + sidecar attempts), `flyleaf://register?q=<term>` (register + read one document's position), `flyleaf://docsync` (enable following). `Tools/kprobe.swift` makes ADP-signed requests from the exported device credentials for fast endpoint testing without rebuilding the app.

## Fallbacks and politeness

- Requests go out via URLSession with Safari's user agent (captured from the login webview for coherence). Amazon has TLS-fingerprinted plain HTTP clients in the past (Node clients need a proxy for this reason); Apple's network stack presents a Safari-family fingerprint, and if a bot challenge is ever detected anyway, the client switches to a hidden WKWebView issuing same-origin `fetch()` calls, which is indistinguishable from the web reader.
- Redirects off the reader host are treated as session expiry and surface as a one-click re-auth, never a retry loop.
- Rate: one library call per poll tick. No book downloads, no renderer, no annotation endpoints.

## Sources

- [transitive-bullshit/kindle-api](https://github.com/transitive-bullshit/kindle-api), TypeScript client this integration mirrors (endpoints, headers, device token flow, progress calculation).
- [Xetera/kindle-api](https://github.com/Xetera/kindle-api), original library; documents the required cookies and Amazon's TLS fingerprinting of non-browser clients.
- [Amazon Kindle Export gist (jkubecki)](https://gist.github.com/jkubecki/d61d3e953ed5c8379075b5ddd8a95f22), community discovery of the library search endpoint shapes.
- [Kindle Web Reader pages writeup (noh.am)](https://noh.am/en/posts/kindle-web-reader-pages/), `loadMetadata` JSONP fields.
