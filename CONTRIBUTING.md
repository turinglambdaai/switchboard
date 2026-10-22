# Contributing

## Development loop

```sh
raco pkg install --auto --name switchboard .
raco test -p switchboard
raco setup --check-pkg-deps switchboard
raco scribble --htmls --dest /tmp/switchboard-doc switchboard-doc/scribblings/switchboard.scrbl
```

CI must be green on `main`; whoever pushes a red `main` fixes or reverts on the spot.

## Rules

- Read `AGENTS.md` before changing code; the invariants there are normative.
- Tests run against the injected transport (`current-post-json`) — never the network.
- Public API changes land in the same change as their scribble documentation and both READMEs.
