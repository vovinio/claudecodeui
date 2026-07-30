# claudecodeui — our version, frozen fork

This repo started as a clone of `siteboon/claudecodeui` (AGPL-3.0) and is now
**ours to develop**. We do not track upstream any more. `origin` is
`vovinio/claudecodeui`; `main` is our version and the branch we ship from.

Every file here is ours, inherited ones included. `AGENTS.md` came from the
original clone, but the fork is frozen — there are no upstream merges left to
conflict with, so edit anything that is useful to edit.

This file is committed (force-added: upstream's `.gitignore` lists `CLAUDE.md`
for contributors' local notes, which no longer applies to us) so it is backed up
on GitHub with the code rather than living only on this disk.

## Workflow

Ordinary trunk-based development. No patch series, no rebasing onto upstream.

```bash
git switch -c feat/thing main     # or fix/thing
# ... edit, commit ...
git switch main && git merge --ff-only feat/thing
git push
```

**The one discipline that matters: keep each change a discrete commit whose
message says *why*.** We may one day want to move onto a newer upstream release.
Doing that is not a merge — after a few hundred upstream commits our code will
reference components that no longer exist, so it is a re-implementation. A list
of small, well-described intents can be re-applied to a new codebase; one
40-file blob commit cannot. That is the whole reason to bother.

`upstream` is still configured, purely as a reference point. Never merge or
rebase from it without deciding to do so deliberately.

## What is ours

The fork point is tagged permanently, so this always answers it:

```bash
git diff --stat upstream-base-v1.37.0..main    # everything we have changed, ever
```

## Running it

Frontend, with hot reload, at `https://dev-claudecodeui.volka.fit`:

```bash
devurl vite claudecodeui
```

There is deliberately **no separate dev backend**. The dev frontend proxies
`/api`, `/ws` and `/shell` to `:3001`, which is production — so the preview shows
real sessions, which is what we want. Consequences: actions in the preview are
real, and server-side changes do not appear there at all.

**Never run a second backend against `~/.cloudcli/auth.db`.** It is
`journal_mode=delete`, so a writer locks the whole file — two processes means
`SQLITE_BUSY` and a corruption window. Losing that database loses all sessions
and history, with no rollback. One backend at a time, always.

To work on `server/`, replace production rather than running alongside it:

```bash
sudo systemctl stop cloudcli
npm run server:dev-watch          # same port, same DB, reloads on save
sudo systemctl start cloudcli     # back to the installed build
```

`code.volka.fit` keeps working throughout, since it is the same port.

## Shipping to production

Production is the globally installed `@cloudcli-ai/cloudcli` package, run by
`cloudcli.service` as `dev`. Build from `main`, and run it from a terminal —
`systemctl restart cloudcli` drops every WebSocket including the session issuing
it.

```bash
git worktree add --detach /tmp/ccui-build main
cd /tmp/ccui-build && npm ci && npm run build && npm pack
sudo npm i -g cloudcli-ai-cloudcli-*.tgz
sudo systemctl restart cloudcli
```

Keep the previous `.tgz` — rollback is one `npm i -g` away. Reinstalling
`@cloudcli-ai/cloudcli` from the npm registry instead would silently drop
everything we have added.

## UI changes

Not a conflict concern any more, but still good structure: prefer new files over
editing existing ones, put theme changes in `tailwind.config.js`, and keep CSS
overrides in their own file rather than growing `src/index.css`.
