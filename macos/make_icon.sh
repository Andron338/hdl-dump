#!/bin/sh
# Renders Sources/PS2HDDManager/AppIconArt.swift into AppIcon.icns (run after changing the artwork).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat "$HERE/Sources/PS2HDDManager/AppIconArt.swift" > "$WORK/render.swift"
cat >> "$WORK/render.swift" <<'EOF'

import AppKit

@MainActor func render(_ px: Int, to path: String) {
    // macOS icons keep a transparent margin around the squircle (824 of 1024 px).
    let art = AppIconArt(size: CGFloat(px) * 824 / 1024)
        .frame(width: CGFloat(px), height: CGFloat(px))
    let r = ImageRenderer(content: art)
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    MainActor.assumeIsolated { render(px, to: "\(dir)/icon_\(name).png") }
}
EOF

mkdir -p "$WORK/AppIcon.iconset"
swiftc -O -o "$WORK/render" "$WORK/render.swift" -parse-as-library 2>/dev/null || swiftc -O -o "$WORK/render" "$WORK/render.swift"
"$WORK/render" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$HERE/AppIcon.icns"
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" "$HERE/AppIcon.png"
echo "Wrote $HERE/AppIcon.icns"
