---
paths:
  - "README.md"
  - "INTEL.md"
  - "CLAUDE.md"
  - "CHANGELOG.md"
  - "agterm/**"
  - "agtermTests/**"
  - "site/**"
  - "docs/**"
  - "cookbook/**"
  - "plugins/**"
  - "packaging/**"
  - "project.yml"
  - "scripts/setup.sh"
  - "scripts/intel-*.sh"
  - ".github/workflows/**"
---

## Intel fork (`legacy/intel`)

`INTEL.md` owns the fork's rules and runbook; this file covers only what a coding agent would otherwise get wrong.

- The README's fork notice, badges, Install section and bug-report line deliberately differ from `site/`.
  The `CLAUDE.md` rule that install commands and the minimum macOS version stay synchronized across README,
  `site/docs.html` and `site/llms.txt` governs upstream's text: never copy the fork's install text into `site/`,
  and never restore upstream's text in README.
- `site/`, `docs/`, `cookbook/`, `plugins/`, `packaging/` and `CHANGELOG.md` stay byte-identical to upstream.
  Their references to upstream releases, the Homebrew cask, Apple Silicon and the upstream issue tracker are
  intended; a change there is an upstream pull request from `master`, never a fork edit.
- `ci.md` describes upstream's unchanged `ci.yml`, which targets `master`. The fork's `intel-ci.yml`
  targets `legacy/intel` pushes/PRs and manual dispatch, with Intel runners and separate check names.
  `INTEL.md` maps upstream gates to its jobs and owns the required drift check at each refresh;
  a clean rebase does not prove new upstream gates reached the Intel workflow.
- A change on `legacy/intel` belongs to one commit of the Intel stack in `INTEL.md` and is folded into it, so the
  stack stays one commit per concern. A fix x86_64 does not need goes upstream from `master` instead; the
  maintainer may carry one temporarily above the stack, as its own commit listed in `INTEL.md`, until upstream has it.
