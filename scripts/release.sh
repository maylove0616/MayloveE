#!/bin/zsh
# Builds a self-contained MayloveE.app (with jdtls and a trimmed Java runtime inside) and packages it
# as build/MayloveE-<version>-macos-arm64.dmg.
#
# Needs a JDK 25+ with jmods to create the runtime: the one in $JLINK_JDK, else java_home's 25+,
# else Homebrew's openjdk.
set -euo pipefail

cd "$(dirname "$0")/.."

jdtls_version=1.63.0
jdtls_build=202610191322
jdtls_sha256=b1f2abe0b3cccb462cf64fb4a5587c7d09df60cf8be7748b152cbd89d018bdc4
# Found with `jdeps --print-module-deps` over the jdtls plugins, plus modules loaded reflectively.
runtime_modules=java.base,java.desktop,java.management,java.naming,java.net.http,java.sql,jdk.compiler,jdk.jdi,jdk.unsupported,jdk.zipfs,jdk.charsets,jdk.management,jdk.xml.dom,jdk.net

scripts/bundle.sh
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)

# jdtls: download once into build/cache and verify it.
mkdir -p build/cache
tarball=build/cache/jdt-language-server-$jdtls_version-$jdtls_build.tar.gz
if [[ ! -f $tarball ]]; then
    curl -fL -o "$tarball.part" \
        "https://download.eclipse.org/jdtls/milestones/$jdtls_version/jdt-language-server-$jdtls_version-$jdtls_build.tar.gz"
    mv "$tarball.part" "$tarball"
fi
echo "$jdtls_sha256  $tarball" | shasum -a 256 -c -

# The release app is assembled in a temporary copy, so build/MayloveE.app stays a plain dev build.
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
app=$staging/MayloveE.app
ditto build/MayloveE.app "$app"

jdtls=$app/Contents/Resources/jdtls
mkdir -p "$jdtls"
# Only what MayloveE launches: the plugins and the Apple Silicon configuration.
tar -xzf "$tarball" -C "$jdtls" plugins features config_mac_arm

# Java runtime for jdtls. java_home falls back to the default JDK when no 25+ is registered,
# so each candidate's version is checked.
jdk=
for candidate in "${JLINK_JDK:-}" "$(/usr/libexec/java_home -v 25+ 2>/dev/null)" \
                 /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home; do
    [[ -n $candidate && -x $candidate/bin/jlink && -d $candidate/jmods ]] || continue
    major=$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$candidate/release")
    if (( major >= 25 )); then
        jdk=$candidate
        break
    fi
done
if [[ -z $jdk ]]; then
    echo "No JDK 25+ with jmods found; set JLINK_JDK." >&2
    exit 1
fi
echo "Creating runtime with $jdk"
# In Resources rather than PlugIns: codesign treats every file under PlugIns as code, and the
# runtime also holds data files (e.g. lib/security/cacerts).
runtime=$app/Contents/Resources/jre
"$jdk/bin/jlink" --add-modules "$runtime_modules" --strip-debug --no-header-files --no-man-pages \
    --compress=zip-6 --output "$runtime"

# Third-party license texts.
licenses=$app/Contents/Resources/Licenses
mkdir -p "$licenses"
cp THIRD_PARTY_NOTICES.md "$licenses/"
for package in SwiftTreeSitter tree-sitter tree-sitter-java; do
    cp ".build/checkouts/$package/LICENSE" "$licenses/$package-LICENSE.txt"
done
unzip -p "$jdtls"/plugins/org.eclipse.jdt.ls.core_*.jar about.html > "$licenses/jdtls-about.html"

# Every Mach-O file in the runtime is signed before the app, which seals them.
find "$runtime" -type f -print0 | while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q Mach-O; then
        codesign --force --sign - "$file"
    fi
done
codesign --force --sign - "$app"
codesign --verify --strict "$app"

# Disk image: the app next to a link to /Applications, to drag it across.
dmg=build/MayloveE-$version-macos-arm64.dmg
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "MayloveE $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"

echo "Packaged $dmg"
shasum -a 256 "$dmg"
