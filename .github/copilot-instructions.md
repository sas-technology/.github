# GitHub Copilot instructions

See [`AGENTS.md`](../AGENTS.md) at the repo root for the full rules.
The three Copilot most often gets wrong:

1. Don't invent or paste in realistic-looking student/staff data for
   examples or tests — use obviously fake placeholders.
2. Don't suggest committing a secret (API key, token, `.env` value)
   even "temporarily" or "for testing."
3. Don't suggest disabling a failing test or lint rule as the fix —
   fix the underlying issue or ask.
