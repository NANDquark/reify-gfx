# Font MSDF Generation

Generate atlas assets using the local tool:

```bash
odin run tools/font_msdf_gen
```

The generator currently uses hardcoded settings in `tools/font_msdf_gen/font_msdf_gen.odin`.

Key constants:

- Input TTF fallback chain: `FONT_TTF_FILENAMES` (ordered, first valid glyph wins)
- Output PNG: `ATLAS_PNG_FILENAME`
- Output JSON: `ATLAS_JSON_FILENAME`
- Face name written to JSON: `FONT_FACE_NAME`
- Packing/generation settings (including `ATLAS_PADDING_PX`, size, and range)

Behavior notes:

- Multiple TTF files are merged into one final atlas/JSON output.
- For each codepoint, the first font in `FONT_TTF_FILENAMES` that provides a valid glyph shape is used.
- If no configured font contains a codepoint, generation still succeeds and emits an empty glyph entry with zero offsets/advance fallback.
- The tool logs warnings listing codepoints that are missing in all configured fonts.
- The atlas always includes a dedicated placeholder box glyph at `id = 0` (from `.notdef`), intended for runtime fallback when a requested glyph is missing.
