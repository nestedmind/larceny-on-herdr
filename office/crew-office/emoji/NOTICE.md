# Emoji images

The six reaction emoji (👍 ✅ ❌ 👀 ❤️ 😂) are drawn from these images, not from a font, because herdr draws emoji
text in one colour (ticket #77).

- Source: https://github.com/googlefonts/noto-emoji, commit `99701e07d3d1fe1bdbcdb14964547f0fd592966f`,
  the files `2D/svg/emoji_u1f44d.svg`, `emoji_u2705.svg`, `emoji_u274c.svg`, `emoji_u1f440.svg`, `emoji_u2764.svg` and
  `emoji_u1f602.svg`. They are copied unchanged to `src/<codepoint>.svg`.
- Licence: Apache License 2.0. The notice in `2D/svg/LICENSE` of that repository covers the images in `2D/svg`, and is
  copied here as `LICENSE`. (The repository's top-level `LICENSE` is the SIL Open Font License, which covers the
  font files, not these images. The installed `NotoColorEmoji` font is under that one, and is not used.)
- `<codepoint>-<px>.png` is the SVG drawn at `<px>` by `<px>` pixels, with Inkscape:
  `inkscape -w <px> -h <px> src/<codepoint>.svg -o <codepoint>-<px>.png`.
  herdr shrinks an image without smoothing, so each one is made at the size it is shown at on screen: 16 px
  at a scale of 1, 20 at 1.25, 24 at 1.5 and 32 at 2. The panel picks the size from the office's `emojiScale` prop.
