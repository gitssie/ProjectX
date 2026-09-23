# XenSpace GitHub Pages / Sileo publication

XenSpace is built on the maintainer's Mac and published from an isolated temporary Git repository. GitHub only serves the generated static site and Sileo repository; it does not build or sign the package.

## One-time setup

1. Push the `main` branch containing the publication scripts.
2. Run the first publication locally.
3. In GitHub, open **Settings → Pages**.
4. Choose **Deploy from a branch**, branch **gh-pages**, folder **/(root)**.
5. Add `https://gitssie.github.io/ProjectX/` to Sileo.

## Publish a fresh build

```sh
scripts/publish_github_pages.sh --dry-run publish
scripts/publish_github_pages.sh publish
```

The real publication performs the following pipeline:

```text
clean warning-gated RootHide build
  → package and entitlement audit
  → local APT repository generation
  → temporary Pages site rendering
  → hash/index/site validation
  → temporary gh-pages checkout
  → ordinary commit and non-force push
```

The `main` worktree is never switched, and generated packages remain ignored there.

## Publish an existing current package

Use this only when the package was already built from the current clean source:

```sh
scripts/publish_github_pages.sh \
  --package "$PWD/packages/com.hydra.projectx_<version>_iphoneos-arm64e.deb" \
  publish
```

The package must be inside `packages/`, match `control`, be `iphoneos-arm64e`, pass the RootHide audit, and be newer than every relevant source file.

## Output

The `gh-pages` branch contains only public release material:

```text
.nojekyll
index.html
icon.png
CydiaIcon.png
launch-mark.png
depiction.json
Packages
Packages.gz
Packages.xz
Packages.zst
Release
pool/com.hydra.projectx_<version>_iphoneos-arm64e.deb
```

Each publication replaces the served snapshot with one internally consistent current package. The commit remains part of `gh-pages` history, while `main` remains source-only.
