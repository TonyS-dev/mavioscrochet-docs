#!/bin/bash

SRC="../mavioscrochet"
DEST="."

echo "🔄 Syncing documentation from $SRC..."

# Root files
cp "$SRC/README.md" "$DEST/"
cp "$SRC/README_ES.md" "$DEST/"
cp "$SRC/LICENSE" "$DEST/"

# Backend docs (only READMEs, avoiding Java code)
mkdir -p "$DEST/backend"
cp "$SRC/backend/README.md" "$DEST/backend/"
cp "$SRC/backend/README_ES.md" "$DEST/backend/"

# Docs folder (syncs the whole docs/ folder, but excludes API_OVERVIEW.md)
rsync -av --delete --exclude="API_OVERVIEW.md" "$SRC/docs/" "$DEST/docs/"

echo ""
echo "✅ Done! Documentation updated successfully."
echo "👉 You can now run 'git status' and commit the changes."
