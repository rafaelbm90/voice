# Releasing Voice

## Tagging a release

Create an annotated tag whose message is the one-line summary you want shown at the top of the GitHub Release:

```bash
git tag -a v0.1.5 -m "Fix popup centering after send"
git push origin v0.1.5
```

The release workflow uses that tag message as the `What Changed` line in the published GitHub Release notes, then appends the install instructions, SHA256, and full changelog link.

## Editing an existing release

Existing GitHub Releases can be edited later in the GitHub UI or with `gh`:

```bash
gh release edit v0.1.5 --notes-file /path/to/release-notes.md
```

Keep the summary brief and user-facing. One sentence is enough.
