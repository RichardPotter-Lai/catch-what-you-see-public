# Catch what you see

Read README.md, GLOSSARY.md, docs/DEVELOPMENT.md and the relevant openspec/specs before editing.

- Native macOS app; text notes and screenshots share the clothesline.
- Markdown and local attachments are authoritative. Search indexes are rebuildable.
- Collection is explicit. Direct selection is preferred; the optional copy fallback runs only after an intentional collection and an eligible failure.
- No OCR, browser extensions, passive clipboard history, telemetry or content upload.
- Clipboard snapshots stay in memory. Do not use unchanged stale clipboard text as a selection or overwrite a known newer copy.
- Preserve source focus and right-click behavior. Source metadata must belong to the captured content or be left unknown.
- Hiding cards, capacity limits and restart never delete saved notes or uncleared temporary screenshots.
- Treat Library as private data. Use synthetic fixtures and isolated test roots.
- Do not modify TCC databases or silently enable permissions, login items or screenshot takeover.
- Keep a single screenshot-settings owner and restore only settings still owned by this app.
- Preserve unknown Markdown fields and external edits. Do not repair documents from stale caches.
- Preserve MIT and third-party notices, use this project's independent name/icon.
- Run the fastest meaningful checks; distinguish mocks, builds and real app compatibility.

