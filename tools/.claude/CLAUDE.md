# Global instructions

## Clickable file paths

Ghostty only linkifies things that look like URLs, and its custom `link` regex
option is not implemented yet (1.3.1). So a bare path is never clickable, but an
OSC 8 hyperlink is -- and Claude Code emits one for a markdown link.

When pointing me at a file (something you created, modified, or want me to open),
write it as a markdown link with a relative display text and an absolute
`file://` target:

    [docs/specs/2026-08-20-spec.md](file:///home/daniel/Source/example/docs/specs/2026-08-20-spec.md)

The display text stays short and relative; the click target is absolute, so it
resolves regardless of cwd. Append `#L42`-style anchors only if you have a reason
to -- they are ignored.

Do not do this for every incidental `path:line` mention inside prose or code
review notes; use it for paths that are the point of the sentence.

## Clickable PR and issue references

Every PR or issue mentioned in a reply gets a markdown link with the full
GitHub URL -- never a bare `#865`:

    [portal#865](https://github.com/Grantigo/portal/pull/865)

This applies everywhere a PR/issue is referenced in prose to me: reviews,
status updates, roadmaps, "what's next" summaries, one-line mentions. When
several repos are in play, prefix the display text with the repo (`selma#75`,
`portal#865`) so bare numbers never collide. There is no volume exception: a
summary naming fifteen PRs links all fifteen.
