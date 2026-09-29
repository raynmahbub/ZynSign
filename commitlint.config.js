/*
 * Conventional Commits — ZynSign.
 *
 * Every commit message is validated against this configuration (CI:
 * 01-build workflow; local: husky commit-msg hook once `npm install`
 * has run). The allowed types are exactly the playbook's list, and they
 * are the same types Release Drafter and the changelog generator read.
 *
 * Interactive authoring: `npm run commit` (Commitizen).
 */
module.exports = {
    extends: ["@commitlint/config-conventional"],
    rules: {
        "type-enum": [
            2,
            "always",
            [
                "feat",
                "fix",
                "refactor",
                "perf",
                "docs",
                "ci",
                "test",
                "build",
                "chore",
                "style",
            ],
        ],
        // Scopes like `feat(signing):` — allow the common casings.
        "scope-case": [2, "always", ["lower-case", "kebab-case", "camel-case"]],
        // Subject casing stays free-form for readability.
        "subject-case": [0],
        // The release train tags reference epics; keep headers concise.
        "header-max-length": [2, "always", 100],
    },
};
