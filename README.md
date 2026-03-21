# REG-Station Theme Index

Curated and processed theme packages for REG-Station.

## How it works

1. `scripts/theme-list.json` defines the curated theme list
2. GitHub Actions monthly workflow clones each theme, processes it (validates, strips videos, downscales oversized images, ETC1-compresses opaque textures), and packages as `.zip`
3. Zips are uploaded as GitHub Release assets (CDN via Fastly)
4. `themes.json` is generated with download URLs and served via jsDelivr CDN

## CDN URLs

```
https://cdn.jsdelivr.net/gh/REG-Linux/theme-index@main/themes.json
https://cdn.jsdelivr.net/gh/REG-Linux/theme-index@main/screenshots/Art-Book-Next.jpg
```

Theme zip downloads are on GitHub Releases (no size limit, CDN-backed).

## Adding a theme

Edit `scripts/theme-list.json`, add an entry, trigger the workflow.

