# Typography

## In the app

**SF Pro**, always through text styles (`ZTypography.*`, which wrap
`Font.largeTitle … caption2`), never a fixed point size, so every screen
scales with Dynamic Type up to the accessibility sizes. Numbers that change
(scores, counts, timers) use `.monospacedDigit()`; the Install Health score
uses `.rounded` design for warmth at display size.

| Role | Style | Weight |
|---|---|---|
| Screen title | `largeTitle` | bold |
| Card title | `headline` | semibold |
| Body | `body` / `subheadline` | regular |
| Metadata | `caption` / `caption2` | regular, `.secondary` |
| Numbers | `title2` / `system(34, rounded)` | bold, monospaced digits |

Rules: sentence case for everything except product names and the greeting;
one weight step between a title and its detail; no all-caps labels.

## The wordmark

"ZynSign" set in **SF Pro Display Bold**, letter-spacing −3.5 %, cap height
aligned to the tile's optical centre (baseline at 70 % of the tile height in
the lockup). The generated SVGs fall back to Segoe UI / Roboto / Helvetica in
that order where SF is unavailable, so the lockup renders on GitHub.

Files: `Assets/Brand/Logo/wordmark.svg`, `wordmark-dark.svg`,
`logo-lockup.svg`, `logo-lockup-dark.svg`.

## Marketing surfaces

Banners, the social preview and App Store screenshots use the same two
weights only — Bold for headlines, Regular for one line of support copy.
Headlines: three words or fewer. Support copy: ten or fewer.
