---
name: work-queue
description: Work the Jira "Planned Next" queue end-to-end - fetch queued KAN tickets, ask all clarifying questions up front, dispatch implementation to Codex CLI in isolated worktrees, review and debate the result, open a PR into develop, and stop for the user's review. Use when the user says to work the queue, pick up planned-next tickets, or invokes /work-queue.
---

# Work the "Planned Next" queue

Semi-automated ticket pipeline. The user drops tickets into the **Planned Next**
column on the KAN board, then invokes this skill. You take each ticket from
clarification through an open PR into `develop` — and **never merge**; the PR is
the review gate where the user takes over.

`jira` lives at `~/.local/bin/jira` — ensure `~/.local/bin` is on PATH.

## Phase 0 — Fetch the queue

```
jira issue list --plain --columns key,summary -q 'project = KAN AND status = "Planned Next"' --order-by rank --reverse
```

Rank order = board order, top first; work tickets in that order.
If the queue is empty, say so and stop. (If the user says they *did* drop
tickets, the column is probably not named exactly `Planned Next` — tell them.)

## Phase 1 — Read and clarify (ALL tickets, up front)

The whole point of this workflow is that the user answers questions once, then
walks away. So before writing any code:

1. Read every queued ticket in full: `jira issue view KAN-<n> --comments 10`.
2. Skim the relevant code so questions are grounded, not generic. Keep
   notes — they become the pointers in each Codex dispatch prompt.
3. Collect the ambiguities from **all** tickets and ask them in one
   front-loaded round of AskUserQuestion (multiple calls if >4 questions, but
   all before implementation starts). Only ask what actually changes the
   implementation — a well-specified ticket gets zero questions.
4. If a ticket is still too vague or blocked after answers (needs external
   credentials, manual host steps, a product decision the user deferred):
   leave it in Planned Next, add a Jira comment explaining what's missing,
   exclude it from this run, and note it in the final summary.

## Phase 2 — Solve with Codex (one ticket at a time, in rank order)

Implementation is delegated to Codex CLI, synchronously and never in parallel.
Each ticket gets an independent worktree and a fresh Codex thread. This Claude
session does judgment and external side effects only: clarify, prepare the
worktree, dispatch, review, commit, and ship. Codex edits and tests inside its
assigned worktree but never commits, pushes, opens PRs, or touches Jira.

For each ticket:

1. Once per run: `git fetch origin`, then sanity-check
   `git merge-base --is-ancestor origin/main origin/develop` — develop must
   contain main; if it doesn't, stop and tell the user instead of basing
   work on a stale develop.
   Also once per run, preflight the Codex sandbox without spending tokens:

   ```bash
   codex sandbox -c 'sandbox_mode="workspace-write"' -- touch .codex-runs/.preflight
   ```

   Any `bwrap:` error means the host cannot run Codex's sandbox — stop and
   tell the user; a dispatch would burn tokens producing a handoff that
   couldn't edit any files. (The known cause: Ubuntu's AppArmor userns
   restriction, fixed 2026-07-18 via `/etc/apparmor.d/bwrap-userns` granting
   `userns` to bwrap and Codex's bundled `codex-resources/bwrap`. If it
   regresses, the profile's glob probably no longer matches the bundled
   bwrap's path — check where the installed codex package actually is.)
   All `codex` invocations in this skill must run outside Claude's own Bash
   sandbox (nested namespaces make bwrap fail at uid-map setup), so run them
   with the sandbox disabled for that command.
2. `jira issue move KAN-<n> "In Progress"`.
3. Define the branch `features/kan-<n>-<short-slug>` and create a sibling
   worktree from `origin/develop`. Resolve its absolute path before dispatch.
   If the branch or target worktree already exists, inspect it and either
   resume that ticket deliberately or stop; never delete or overwrite it just
   to make the command succeed.
4. Under the main checkout's ignored `.codex-runs/KAN-<n>/` directory, write
   `prompt.md`. It must contain the ticket key, summary, full description,
   acceptance criteria, user clarifications verbatim, relevant file pointers,
   known gotchas, exclusions, and an instruction to follow `AGENTS.md` and
   `CLAUDE.md`. Do not interpolate ticket text into a shell command.
5. Dispatch from stdin. Replace the placeholders with absolute paths; keep the
   event stream and stderr out of Claude's context:

   ```bash
   codex -m gpt-5.6-sol \
     -c 'model_reasoning_effort="high"' \
     -a never \
     -s workspace-write \
     -C <absolute-worktree> \
     --add-dir <absolute-main-checkout>/.git \
     exec --json \
     -o <absolute-run-dir>/final.md \
     - \
     < <absolute-run-dir>/prompt.md \
     > <absolute-run-dir>/events.jsonl \
     2> <absolute-run-dir>/stderr.log
   ```

   A non-zero exit is a failed dispatch. Inspect only the relevant tail of
   `stderr.log`; do not dump the entire log into the conversation.
   Exit 0 is *not* success: a run whose sandbox is broken still exits 0 with
   a `turn.completed` event. If `final.md` reports sandbox or permission
   failures (`bwrap:`, `Failed to write file`), or the worktree has no
   changes where changes were expected, treat the dispatch as failed — do
   not enter the review loop on it.
   The `--add-dir <absolute-main-checkout>/.git` flag is mandatory in a
   worktree: its git metadata lives in the main checkout's
   `.git/worktrees/…`, which is otherwise read-only in the sandbox and makes
   every git write fail.
6. Extract and save the exact thread ID without loading the JSONL stream into
   context:

   ```bash
   jq -r 'select(.type == "thread.started") | .thread_id' \
     <absolute-run-dir>/events.jsonl | sed -n '1p' \
     > <absolute-run-dir>/thread-id
   ```

   Require a non-empty `thread-id` and a `turn.completed` event before
   treating the run as successful. Read `final.md`, then inspect the
   worktree's actual status and diff; the handoff is a claim, not proof.
7. Tickets are independent branches, not stacked. If two queued tickets
   genuinely depend on each other, point the second Codex worker at the first
   ticket's branch as its base, ship them as one PR, and say so in the
   summary.
8. Review the diff yourself against the ticket, `CLAUDE.md`, and
   `AGENTS.md`. Run relevant checks independently. If changes are needed,
   write a focused `review-<round>.md`, then resume the same thread (maximum
   two rounds):

   ```bash
   codex -m gpt-5.6-sol \
     -c 'model_reasoning_effort="high"' \
     -a never \
     -s workspace-write \
     -C <absolute-worktree> \
     --add-dir <absolute-main-checkout>/.git \
     exec resume --json \
     -o <absolute-run-dir>/review-<round>-final.md \
     "$(< <absolute-run-dir>/thread-id)" \
     - \
     < <absolute-run-dir>/review-<round>.md \
     > <absolute-run-dir>/review-<round>-events.jsonl \
     2> <absolute-run-dir>/review-<round>-stderr.log
   ```

   Ask Codex to label each point Accept, Disagree, or Uncertain and provide
   evidence. Verify fixes rather than accepting the response at face value.
   If a substantive disagreement remains after two rounds, stop and give the
   user both positions plus the decisive test or decision needed.
9. Once accepted, run `make check` in the ticket worktree. Claude makes the
   one-line commit containing the ticket key, with no attribution trailers.
   If Codex returns an open product/scope question, treat the ticket as blocked
   unless the user is available to answer.

## Phase 3 — Review gate (never merge)

For each completed ticket:

1. Push the branch, then open a PR into develop (this skill is explicit
   authorization to open PRs — the usual "don't open PRs unless asked" rule
   is satisfied by the user invoking it):
   `gh pr create --base develop --title "<one-liner> (KAN-<n>)" --body ...`
   Body: what changed and why, how it was tested, link to the Jira ticket.
2. `jira issue move KAN-<n> "In Review"` and
   `jira issue comment add KAN-<n> "PR: <url>"`.
3. **Never** merge the PR, never push to `develop` or `main`, never delete
   branches. The user reviews and merges.

## Codex-unavailable fallback

If a dispatch fails because Codex is out of usage quota or the service is
unreachable (check the tail of `stderr.log` — do not confuse this with a code
or sandbox failure), fall back to the `ticket-solver` agent for the remaining
tickets rather than abandoning the queue. Same contract per ticket: work in
the ticket's already-created worktree and branch, one agent per ticket, and
pass it the full `prompt.md` brief plus the worktree's absolute path. Review
its diff in the main chat exactly as for Codex; feedback goes back to the
same agent via SendMessage instead of `codex exec resume`, with the same
two-round limit. Unlike Codex, ticket-solver makes the one-line commit
itself. Label each ticket in the final summary with the worker that
implemented it (Codex or ticket-solver).

## Failure handling

If Codex can't get checks green, returns an unresolved scope question, or the
ticket turns out to be blocked mid-implementation: do not push broken work.
Move the ticket back to `Planned Next` with a Jira comment explaining what
happened, preserve the worktree and branch for inspection, and report them in
the summary. Delete neither automatically.

## Final summary (always)

End with a per-ticket rundown the user can act on from their phone:
ticket → branch → PR URL → check status, plus skipped/blocked tickets with
reasons, and an explicit "ready for your review" handoff.
