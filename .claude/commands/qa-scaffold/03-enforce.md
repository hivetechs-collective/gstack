# Stage 03 — Install ESLint `require-data-testid` rule and register it

**Prerequisites:** Stage 02 completed; `.claude/qa-profile.json` has `stage_status["03-enforce"] == "pending"`.
**Purpose:** render the custom ESLint rule template into the repo and wire it up in the repo's ESLint config so interactive elements that lack `data-testid` fail lint.
**Scope:** ESLint only. CI wiring is covered in Stage 04's verification — Stage 03 does not edit CI workflows.

---

## 3.1 Render the rule file

| Template                                   | Destination                           |
| ------------------------------------------ | ------------------------------------- |
| `templates/eslint-testid-rule.js.template` | `eslint-rules/require-data-testid.js` |

Apply the same backup protocol from Stage 02 §2.4:

- Does not exist → write.
- Exists and matches → no-op.
- Exists and differs → backup, diff, prompt, default to abort.

The rule is framework-agnostic for JSX/TSX (React, Next, Remix, Solid). For Vue, Svelte, and Angular, Stage 03 additionally installs the upstream plugin (see 3.4) and registers equivalent rules — the custom rule is the JSX reference implementation.

---

## 3.2 Detect the ESLint config file

Check in priority order:

1. `eslint.config.{js,mjs,cjs,ts}` → flat config (ESLint 9+)
2. `.eslintrc.{js,cjs,mjs}` → legacy config
3. `.eslintrc.json` or `.eslintrc.yaml`/`.eslintrc.yml` → legacy config
4. `package.json` `"eslintConfig"` key → legacy inline config

If none exist: Stage 03 writes a minimal flat config at `eslint.config.js`. Do not assume ESLint was previously wired — a brand-new repo scaffold is a valid path.

Record the detected config file in qa-profile.json for Stage 04.

---

## 3.3 Flat-config registration (ESLint 9+)

For flat config, append this block to the array (prepend imports at top):

```js
// eslint.config.js
import requireDataTestid from "./eslint-rules/require-data-testid.js";

export default [
  // ...existing configs preserved verbatim...
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: {
      local: {
        rules: {
          "require-data-testid": requireDataTestid,
        },
      },
    },
    rules: {
      "local/require-data-testid": "error",
    },
  },
];
```

Use **Edit** against the existing file (never Write-over). If the config uses CommonJS (`module.exports`), render the equivalent `require()` + `module.exports.push(...)` variant. Never mix ESM and CJS syntax in one file.

---

## 3.4 Framework-specific plugin install

| Framework              | Upstream plugin installed                              | Additional rule registered                                                                                      |
| ---------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| React/Next/Remix/Solid | none (custom rule covers JSX/TSX)                      | `local/require-data-testid: 'error'` on `**/*.{jsx,tsx}`                                                        |
| Vue                    | `eslint-plugin-vue` (already standard in Vue projects) | Custom Vue variant of the rule matching `<template>` interactive elements. Stage prints exact snippet to paste. |
| Svelte                 | `eslint-plugin-svelte`                                 | Custom Svelte variant. Stage prints exact snippet.                                                              |
| Angular                | `@angular-eslint/eslint-plugin-template`               | Custom template-rule variant. Stage prints exact snippet.                                                       |

For Vue/Svelte/Angular the custom rule is a **manual paste-in** for v1 — the auto-install path is JSX/TSX only. Document this clearly and record in qa-profile.json:

```json
"enforce_manual_steps": [
  "Paste Svelte rule snippet into eslint.config.js (see Stage 03 output)"
]
```

Manual steps do NOT block Stage 03 from marking `ok` — the rule is installed, even if wiring is partial. Stage 04 re-verifies.

---

## 3.5 Legacy-config registration

If the repo uses legacy `.eslintrc.*`:

```json
{
  "plugins": ["local"],
  "rules": {
    "local/require-data-testid": "error"
  },
  "overrides": [
    {
      "files": ["**/*.{jsx,tsx}"],
      "rules": {
        "local/require-data-testid": "error"
      }
    }
  ]
}
```

Plus instruct the user to configure the `local` plugin via `rulePaths` in their `.eslintrc` or an `eslint-plugin-local-rules` adapter. Print the exact snippet. Do NOT attempt to npm-install anything; config-only edits.

---

## 3.6 Add lint script to `package.json`

If `package.json` has no `"lint"` script, add:

```json
{
  "scripts": {
    "lint": "eslint ."
  }
}
```

If `"lint"` exists, leave it — do not modify. Print a hint:

```
Existing lint script preserved. Verify that `npm run lint` covers **/*.{jsx,tsx}
so the new rule actually runs.
```

---

## 3.7 Pre-commit hook (optional, gated by profile)

| Profile       | Pre-commit wiring                                                                |
| ------------- | -------------------------------------------------------------------------------- |
| Tier-Light    | Skip. ESLint-on-commit is friction; Light profile leaves it to CI + user choice. |
| Tier-Standard | Offer to install `lint-staged` + `husky` (Yes/No prompt, default No).            |
| Tier-Full     | Install `lint-staged` + `husky` automatically with `npx husky init`.             |

When installing:

```json
// package.json
{
  "lint-staged": {
    "**/*.{jsx,tsx}": "eslint --max-warnings=0"
  }
}
```

And `.husky/pre-commit`:

```sh
#!/bin/sh
npx lint-staged
```

Do not replace an existing `.husky/pre-commit` — backup + prompt per §2.4 protocol. Never silently clobber a user's git hooks.

---

## 3.8 Downgrade escape hatch (documented)

The rule is installed at severity `error`. For **legacy-surface migration** the user may temporarily downgrade:

```js
// In a per-surface override block
rules: {
  'local/require-data-testid': ['warn', {}], // TODO(2026-Q3): re-enable as error after migrating legacy pages
}
```

Stage 03 does not render this block. It documents the escape hatch in the run log and in the rendered rule's header comment so a future reader knows the path exists without encouraging it.

---

## 3.9 Wiring verification (smoke)

After writing the config edits:

```bash
npx eslint --print-config <sample-jsx-file>  # any .jsx/.tsx file in the repo
```

Assert the output contains `"local/require-data-testid": "error"`. If not, the config edit didn't take effect — print the detected file, the block added, and the eslint output, then exit 2 without marking Stage 03 `ok`. This catches config files that use rule-merging (shared configs, `extends`) that silently drop plugin rules.

---

## 3.10 Update qa-profile.json

```json
{
  "stage_status": {
    "03-enforce": "ok"
  },
  "enforce_manifest": {
    "eslint_config_path": "eslint.config.js",
    "rule_file": "eslint-rules/require-data-testid.js",
    "wired_for": ["jsx", "tsx"],
    "manual_steps": [],
    "precommit_installed": false
  }
}
```

---

## 3.11 Exit conditions

| Condition                                        | Exit                                                                                                   |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Rule file rendered + config wired + smoke passes | Stage 03 marked ok; proceed to Stage 04.                                                               |
| Config file cannot be edited automatically       | Write the exact snippet to stdout; mark stage `partial`; user pastes manually; re-invoke to re-verify. |
| Rule wiring not detected after edit              | Exit 2; stage left as `pending`; do not mark `ok`.                                                     |
| Vue/Svelte/Angular project                       | Mark stage `ok` with `manual_steps` populated; user pastes framework variant.                          |
