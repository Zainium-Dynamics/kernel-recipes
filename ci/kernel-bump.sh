#!/bin/sh
# ci/kernel-bump.sh — move the kernel recipe to the newest Linux on kernel.org.
#
# The recipe is the directory whose manifest.toml has `_kernel = true`. A newer
# release of the same series is taken as soon as it is out; a new series (7.4
# after 7.3) only from its first point release (7.4.1), as rolling distributions
# do. linux-surface's patches for the series are taken fresh from its repository each
# time. Every patch of the recipe must apply to the tree, or the job fails. On
# success the recipe carries the new version (pkgrel back to 0, or one higher when
# only the Surface patches changed) and the version is written to $GITHUB_OUTPUT as
# `version`; with nothing new, `version` is empty.

set -eu

out="${GITHUB_OUTPUT:-/dev/null}"

manifest=$(grep -l '^_kernel *= *true' ./*/manifest.toml | head -n 1)
[ -n "$manifest" ] || { echo "no kernel recipe (a manifest.toml with _kernel = true)" >&2; exit 1; }
recipe=$(dirname "$manifest")
cur=$(sed -n 's/^pkgver=//p' "$recipe/ZEXBUILD")
series() { echo "$1" | cut -d. -f1,2; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]; }

# every linux-<version>.tar.xz in v<major>.x
releases() {
    curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v$1.x/" 2>/dev/null \
        | grep -o 'linux-[0-9][0-9.]*\.tar\.xz' | sed 's/^linux-//; s/\.tar\.xz$//' | sort -uV
}

major=${cur%%.*}
new=""
for v in $(releases "$major") $(releases $((major + 1))); do
    newer "$cur" "$v" || continue
    # a new series waits for its first point release
    if [ "$(series "$v")" != "$(series "$cur")" ] && [ "$(echo "$v" | tr -cd . | wc -c)" -lt 2 ]; then
        continue
    fi
    if [ -z "$new" ] || newer "$new" "$v"; then
        new=$v
    fi
done

# linux-surface's patches and config for the series, fresh every week. 0001-secureboot is
# left out: it reverts the PE header's NX flag and adds a lockdown bypass for hibernation.
target=${new:-$cur}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ser=$(series "$target")
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/linux-surface/linux-surface "$tmp/ls"
(cd "$tmp/ls" && git sparse-checkout set "patches/$ser" configs)
[ -d "$tmp/ls/patches/$ser" ] || { echo "linux-surface has no patches for $ser yet" >&2; exit 1; }
rm -f "$recipe"/surface-*.patch
for p in "$tmp/ls/patches/$ser"/*.patch; do
    case "$(basename "$p")" in *secureboot*) continue ;; esac
    cp "$p" "$recipe/surface-$(basename "$p")"
done
cp "$tmp/ls/configs/surface-$ser.config" "$recipe/surface.config"
list=$(cd "$recipe" && ls surface-0*.patch)
LIST=$list awk '
    /^surface-[0-9].*\.patch$/ { next }
    /^zainium\.config$/ && !done { n = split(ENVIRON["LIST"], l, "\n"); for (i = 1; i <= n; i++) print l[i]; done = 1 }
    { print }
' "$recipe/ZEXBUILD" > "$tmp/ZEXBUILD" && cat "$tmp/ZEXBUILD" > "$recipe/ZEXBUILD"
surface_changed=$(git status --porcelain -- "$recipe" | grep -c . || true)

if [ -z "$new" ] && [ "$surface_changed" = 0 ]; then
    echo "$recipe: Linux $cur is the newest and linux-surface has not changed"
    echo "version=" >> "$out"
    exit 0
fi
[ -n "$new" ] && echo "$recipe: Linux $new is out (the recipe has $cur)"
[ "$surface_changed" != 0 ] && echo "$recipe: linux-surface patches changed"

tarball="linux-$target.tar.xz"
curl -fsSL -o "$tmp/$tarball" "https://cdn.kernel.org/pub/linux/kernel/v${target%%.*}.x/$tarball"
tar -xJf "$tmp/$tarball" -C "$tmp"

for p in $(sed -n 's/^\([0-9a-z-]*\.patch\)$/\1/p' "$recipe/ZEXBUILD"); do
    # applied in order on the scratch tree: a Surface patch can build on the one before it
    if ! (cd "$tmp/linux-$target" && patch -p1 -s) < "$recipe/$p"; then
        echo "$p does not apply to Linux $target: update the patch by hand" >&2
        exit 1
    fi
    echo "$p applies to Linux $target"
done

if [ -n "$new" ]; then
    sed -i "s/^pkgver=.*/pkgver=$new/; s/^pkgrel=.*/pkgrel=0/" "$recipe/ZEXBUILD"
    # a recipe that pins the tarball's sha256 gets the new one
    if grep -q '^sha256sums=' "$recipe/ZEXBUILD"; then
        sum=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
        sed -i "s/^sha256sums=\"[0-9a-f]*  linux-\$pkgver.tar.xz\"/sha256sums=\"$sum  linux-\$pkgver.tar.xz\"/" "$recipe/ZEXBUILD"
    fi
    for m in "$recipe"/*manifest.toml; do
        sed -i -E "s/^(version *= *)\"[^\"]*\"/\1\"$new\"/" "$m"
    done
    version=$new
else
    rel=$(( $(sed -n 's/^pkgrel=//p' "$recipe/ZEXBUILD") + 1 ))
    sed -i "s/^pkgrel=.*/pkgrel=$rel/" "$recipe/ZEXBUILD"
    version="$cur-r$rel"
fi

echo "version=$version" >> "$out"
echo "package=$(sed -n 's/^pkgname=//p' "$recipe/ZEXBUILD")" >> "$out"
