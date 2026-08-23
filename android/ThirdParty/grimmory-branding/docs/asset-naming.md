# Asset Naming

This repository uses a stable naming convention so designers, developers, and
automation tools can all refer to the same asset set consistently.

## Dimensions of an exported asset

Every generated output is defined by:

- `brandVariant`: `bookmark-red` or `bookmark-white`
- `accent`: one entry from `accents.json`
- `asset`: one of the six canonical asset families
- `backgroundVariant`: optional, only for background-enabled assets
- `format`: `svg` or `png`

Template inputs are intentionally separate from generated outputs:

- source template: `templates/<asset>.svg`
- generated output: `dist/<brandVariant>/<accent>/<file>`

## Canonical asset families

- `grimmory`
- `g-book`
- `g-book-squared`
- `g-book-squared-with-background`
- `g-book-squared-with-padding`
- `g-book-squared-with-padding-and-background`

## Directory structure

```text
dist/<brandVariant>/<accent>/
```

Examples:

```text
dist/bookmark-red/orange/
dist/bookmark-white/lavenderDream/
```

## File names

Non-background assets:

```text
<asset>.<ext>
```

Background-enabled assets:

```text
<asset>.<backgroundVariant>.<ext>
```

Examples:

```text
grimmory.svg
g-book.png
g-book-squared.svg
g-book-squared-with-background.light-bg.svg
g-book-squared-with-background.dark-bg.png
g-book-squared-with-padding-and-background.light-bg.svg
```

## Background values

- `light-bg` background: `#FFFFFF`
- `dark-bg` background: `#1E1E1E`

## Bookmark values

- `bookmark-red` brand variant bookmark: `#FF2126`
- `bookmark-white` brand variant bookmark: `#FFFFFF`

## Background generation rules

- `bookmark-red` background assets generate both `light-bg` and `dark-bg`
- `bookmark-white` background assets generate `dark-bg` only

## Why this convention

- easy to browse in GitHub
- easy to script in build pipelines
- avoids ambiguous file names like `logo-final-dark-new.svg`
- keeps asset family separate from accent and background treatment
