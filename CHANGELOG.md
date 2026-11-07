# Changelog

## Unreleased

- Home screen, "Chi phí": Codex spend now shows up. The box reads every Codex home (`~/.codex`, `~/.codex-*`, `~/.codex-accounts/*`, each real folder once), not only one, so the Astra runs of every account are counted. The gpt-6 models (astra, sol, luna, terra, 6.1, cyber, rosalind, astra-law) now have prices, cache writes are priced, and a request above 272,000 input tokens is billed at the higher long-context rate (2x input and cache, 1.5x output) for the models whose OpenAI page states it.
