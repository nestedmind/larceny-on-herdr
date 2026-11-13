# larceny-on-herdr

larceny-on-herdr runs the [larceny](https://github.com/nestedmind/larceny) AI dev crew as separate Claude Code sessions in [herdr](https://github.com/herdrdev/herdr) panes, instead of as subagents. One crew works across a workspace of several repos. A pixel-office view on top comes later.

It uses larceny's crew, process and skills, and changes only how agents start and talk to each other. Larceny decides, herdr executes, the office shows. Neither upstream is forked.

**Status:** phase 0 (spikes). Nothing here is ready to use yet. See [docs/PLAN.md](docs/PLAN.md) for the plan, which is the source of truth.

## Install and PATH

Add the repo as a local marketplace and install the plugin:

```
/plugin marketplace add <path-to-this-repo>
/plugin install larceny-on-herdr@larceny-on-herdr
```

The plugin declares `larceny` (from the `larceny` marketplace) as a dependency, and the marketplace allows that cross-marketplace install.

Claude Code puts a plugin's `bin/` on the Bash tool's `PATH` while the plugin is enabled, so agents can run `loh` directly. Your own shell and herdr terminals do not get that, so put it on `PATH` by hand:

```
export PATH="<path-to-this-repo>/bin:$PATH"
```

## Not affiliated with herdr

This is a community project. It is not affiliated with, endorsed by or supported by the herdr project or its authors.

## License

MIT. See [LICENSE](LICENSE).
