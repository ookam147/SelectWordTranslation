#!/bin/bash

# Auto-navigate to the script's directory
cd "$(dirname "$0")"

echo "🔨 Building with Swift Package Manager..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "❌ Build failed."
    exit 1
fi

# Configuration
APP_NAME="SelectWordTranslation"
APP_BUNDLE="$APP_NAME.app"
SOURCES="Sources/$APP_NAME"
EXECUTABLE_PATH=".build/release/$APP_NAME"

echo "🧹 Cleaning old app bundle..."
rm -rf "$APP_BUNDLE"

echo "📂 Creating App Bundle Structure..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "📦 Installing Executable..."
cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "📝 Installing Info.plist..."
if [ -f "$SOURCES/Info.plist" ]; then
    cp "$SOURCES/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "❌ Error: Info.plist not found"
    exit 1
fi

echo "ℹ️  Creating PkgInfo..."
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "🛡️  Removing quarantine..."
xattr -cr "$APP_BUNDLE"

echo "✍️  Signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ $APP_BUNDLE ready!"
echo "� You can now open it in Finder."
