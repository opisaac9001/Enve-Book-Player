# grimmory-branding

Official Grimmory brand assets plus generated SVG and PNG variants for every
supported accent color and background treatment.

## Licensing

- Repository code, scripts, and supporting metadata are licensed under
  [MIT](./LICENSE).
- Brand assets are not MIT licensed. They are governed by
  [ASSET-LICENSE.md](./ASSET-LICENSE.md) and [TRADEMARKS.md](./TRADEMARKS.md).

If you are using Grimmory branding in another project, review the asset and
trademark terms before redistributing or modifying the files.

## Download

Use this repository in one of three ways:

1. Download a GitHub Release archive if you just need the ready-made assets.
2. Browse the generated files under `dist/` if you want a specific asset
   variant directly from the repo.
3. Clone the repo and regenerate outputs locally if you want to swap in updated
   source SVGs or produce fresh PNG exports.

If you are publishing Grimmory in another project, prefer the generated files in
`dist/` rather than editing the template SVGs directly.

## Default accent

Grimmory branding defaults to the `orange` accent.

If a consumer is unsure which accent to use, or if no accent is explicitly
specified, use `orange`.

This applies to:

- brand assets in documentation
- integrations and third-party references
- marketing and promotional usage
- default generated branding selections

In short: all standard Grimmory brand usage should use `orange` by default.

## Quick start

If you only need official assets:

- go to `dist/<brand-variant>/<accent>/`
- pick the asset family you need
- use SVG when possible
- use PNG when you need raster output

Most people will want one of these first:

- `grimmory.svg` for the full wordmark
- `g-book.svg` for a standalone mark
- `g-book-squared-with-background.light-bg.svg` for app icons or social cards on a
  light background
- `g-book-squared-with-background.dark-bg.svg` for app icons or social cards on a
  dark background

If you are choosing an accent for a general-purpose use case, start with:

- `dist/bookmark-red/orange/`
- `dist/bookmark-white/orange/`

## Repository layout

```text
accents.json               Accent palette source of truth
docs/                      Consumer and maintainer documentation
scripts/                   Asset generation scripts
templates/                 Source SVG masters
dist/                      Generated SVG and PNG outputs
```

## Naming convention

The repository uses a stable three-part naming model:

1. `brandVariant`
2. `accent`
3. `asset file name`

Directory structure:

```text
dist/<brand-variant>/<accent>/
```

Examples:

```text
dist/bookmark-red/orange/
dist/bookmark-white/coralSunset/
```

Asset file naming rules:

- plain assets keep the asset name directly
- background assets add a `.light-bg` or `.dark-bg` suffix before the extension
- file names stay lowercase kebab-case
- accent names keep their canonical app-facing names

Examples:

```text
grimmory.svg
g-book.svg
g-book-squared.svg
g-book-squared-with-padding.svg
g-book-squared-with-background.light-bg.svg
g-book-squared-with-background.dark-bg.svg
g-book-squared-with-padding-and-background.light-bg.svg
g-book-squared-with-padding-and-background.dark-bg.svg
```

Recommended language for docs and releases:

- "brand variant" means `bookmark-red` or `bookmark-white`
- "background variant" means `light-bg` or `dark-bg` background treatment
- "accent" means one palette entry from `accents.json`
- "asset family" means one of the six logo/wordmark outputs

## Which file should I use?

Use `grimmory` when:

- you have room for the full brand name
- the logo is acting as a product or company signature
- you want the clearest brand recognition

Use `g-book` when:

- you need a standalone mark without a square canvas
- the logo is being placed inline with other UI or partner marks
- horizontal or flexible layout matters more than icon consistency

Use `g-book-squared` when:

- you want a square icon with no baked-in background
- the destination already provides its own container or background
- you need the cleanest compositing flexibility

Use `g-book-squared-with-background` when:

- you need a self-contained square icon
- the destination expects a ready-to-use icon tile
- you want explicit light and dark background exports

Use `g-book-squared-with-padding` when:

- you want more breathing room around the mark
- the destination crops tightly
- the mark needs to feel less dense at small sizes

Use `g-book-squared-with-padding-and-background` when:

- you need a padded icon tile with a built-in background
- the asset will be used in app launchers, directories, listings, or social
  cards
- you want the safest export for general reuse

Use SVG when:

- the platform supports vector graphics
- the asset may be scaled
- crisp rendering matters

Use PNG when:

- the destination does not support SVG
- you need a quick raster drop-in
- the upload target requires PNG specifically

If you do not have a specific accent requirement, use the `orange` accent.

## Brand variants

Each brand variant includes these assets:

- `grimmory`
- `g-book`
- `g-book-squared`
- `g-book-squared-with-background`
- `g-book-squared-with-padding`
- `g-book-squared-with-padding-and-background`

Brand variants:

- `bookmark-red`
- `bookmark-white`

Background styles:

- `light-bg` with `#FFFFFF`
- `dark-bg` with `#1E1E1E`

For every accent color, the generator writes:

- SVG with the official `300 -> 500` gradient
- PNG raster export derived from the SVG

For the assets that include a background, the generator creates:

- `bookmark-red`: both `light-bg` and `dark-bg`
- `bookmark-white`: `dark-bg` only

## Background guidance

Background-enabled assets are exported in both official treatments:

- `light-bg` background: `#FFFFFF`
- `dark-bg` background: `#1E1E1E`

As a rule of thumb:

- use `bookmark-red` when you want both light and dark background-ready variants
- use `bookmark-white` when you specifically want white-mark assets on dark backgrounds
- use non-background assets when the destination already supplies the backdrop

## Source of truth

The intended workflow is:

1. Export your final source SVGs from your editor of choice.
2. Replace the placeholder files in `templates/`.
3. Keep the color placeholders in the SVGs:

   - `{{ACCENT_NAME}}`
   - `{{PRIMARY_300}}`
   - `{{PRIMARY_400}}`
   - `{{PRIMARY_500}}`
   - `{{BG_COLOR}}` for the background-enabled assets
   - `{{BOOKMARK_COLOR}}` for the variant-specific bookmark fill

4. Run the generator.

The current template files are placeholders so the repo scaffolding is complete
and the generator can be tested immediately.

## For maintainers

When replacing placeholder templates with final image editor exports:

1. Convert text to outlines before export.
2. Preserve the canonical file names in `templates/`.
3. Keep the token placeholders intact:
   - `{{PRIMARY_300}}`
   - `{{PRIMARY_400}}`
   - `{{PRIMARY_500}}`
   - `{{BG_COLOR}}`
   - `{{BOOKMARK_COLOR}}`
4. Avoid manually exporting every accent from your image editor. Update the source SVGs once
   and regenerate from the repo.

## Generate assets

Install dependencies:

```bash
npm install
```

Generate SVG and PNG assets:

```bash
npm run generate
```

This command also refreshes the full release archive:

```text
grimmory-branding.zip
```

The archive includes:

- `dist/`
- `README.md`
- `LICENSE`
- `ASSET-LICENSE.md`
- `TRADEMARKS.md`
- `docs/`
- `accents.json`

Generate SVG assets only:

```bash
npm run generate:svg
```

## Output structure

Generated files are written to:

```text
  dist/
  bookmark-red/<accent>/
  bookmark-white/<accent>/
```

Each accent directory contains:

- `grimmory.svg`
- `grimmory.png`
- `g-book.svg`
- `g-book.png`
- `g-book-squared.svg`
- `g-book-squared.png`
- `g-book-squared-with-padding.svg`
- `g-book-squared-with-padding.png`
- `g-book-squared-with-background.light-bg.svg`
- `g-book-squared-with-background.light-bg.png`
- `g-book-squared-with-background.dark-bg.svg`
- `g-book-squared-with-background.dark-bg.png`
- `g-book-squared-with-padding-and-background.light-bg.svg`
- `g-book-squared-with-padding-and-background.light-bg.png`
- `g-book-squared-with-padding-and-background.dark-bg.svg`
- `g-book-squared-with-padding-and-background.dark-bg.png`

The generator also writes `dist/manifest.json`.

## Brand usage

The Grimmory name and logos are brand assets. Before reusing them, check
[ASSET-LICENSE.md](./ASSET-LICENSE.md) and [TRADEMARKS.md](./TRADEMARKS.md).

In general:

- do use the official generated assets as published
- do keep proportions, spacing, and colors intact
- do use the `orange` accent unless a specific alternate accent is intentionally
  required
- do pick the correct background treatment for the destination
- do not invent new accent ramps or recolor the bookmark treatment
- do not stretch, crop, or remix the official marks into new logos

## Recommended GitHub release packaging

If you publish GitHub Releases, package them in both forms:

- a full release archive containing everything in `dist/`
- optional convenience archives split by brand variant

Suggested names:

```text
grimmory-branding-v1.0.0.zip
grimmory-branding-bookmark-red-v1.0.0.zip
grimmory-branding-bookmark-white-v1.0.0.zip
```

If you also want per-accent bundles later, keep the same pattern:

```text
grimmory-branding-bookmark-red-orange-v1.0.0.zip
```

## Recommended repository language

Use these exact asset labels in the README, manifests, and releases so the repo
stays internally consistent:

- `grimmory`
- `g-book`
- `g-book-squared`
- `g-book-squared-with-background`
- `g-book-squared-with-padding`
- `g-book-squared-with-padding-and-background`

## Notes

- The app currently uses the accent palette `300` and `500` stops for the logo
  gradient, and `400` can be used for infill or solid accent details inside the
  brand artwork.
- Grimmory branding falls back to the `orange` accent by default, and standard
  brand usage should use `orange` unless there is a deliberate reason to choose
  another supported accent.
- Bookmark color is variant-specific:
  - `bookmark-red` brand variant: `#FF2126`
  - `bookmark-white` brand variant: `#FFFFFF`
- `noir` is intentionally excluded here because it is surface-derived rather
  than a fixed accent color.
- Background-enabled assets are exported with:
  - `bookmark-red`: `#FFFFFF` and `#1E1E1E`
  - `bookmark-white`: `#1E1E1E` only
- The repository code is MIT licensed. Brand assets are governed by
  `ASSET-LICENSE.md` and `TRADEMARKS.md`.
