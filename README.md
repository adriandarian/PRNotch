# PR Notch

PR Notch is a native macOS left-edge companion for pull requests you authored. It keeps a 6-point tab at the physical left edge of the selected display, reveals a compact rail on hover, and opens a detailed PR flyout without requiring GitHub tabs to stay open.

## Status colors

- Green: GitHub reports the pull request clean and mergeable.
- Red: one or more required CI checks are failing.
- Yellow: reviewer feedback, a merge conflict, or an approved branch update needs attention.
- Blue: CI is running, human review is pending, or another merge gate is still waiting.

Red has the highest priority, followed by yellow, blue, and green. Every flyout starts with one primary status derived from the same state as its rail ring; reviewer activity is shown separately.

## PR relationships

When related pull requests are visible together in the rail, a straight vertical connector spans only the empty gap between their ring edges on the column's center axis. If another ring sits between the endpoints, the connector stops at its outer wall and resumes from the opposite wall. Connectors never enter a ring or branch sideways:

- Solid: one pull request explicitly links to the other. GitHub cross-reference events strengthen a relationship only when both pull requests also share a work-item reference, so incidental timeline mentions cannot merge unrelated ticket groups.
- Dashed: both pull requests share a Jira-style ticket key or the same linked GitHub issue.
- Arrow: the source pull request explicitly says it depends on, is blocked by, or is stacked on the pull request at the arrowhead.

Dependency takes precedence over a direct link, and a direct link takes precedence over a shared ticket, so each pair has one unambiguous connector. Hover help identifies the related repository and pull request number.

Related pull requests are kept together as one contiguous group. Each group stays anchored at the position of its most urgent member, while members preserve their normal attention and recency order inside the group.

## GitHub data

PR Notch uses the locally installed GitHub CLI and its authenticated account. Its queue query requests open, non-draft pull requests authored by `@me`, including review decisions, mergeability, check runs, required checks from branch protection and active repository rulesets, compact review-thread state, PR body and branch references, linked issues, GitHub cross-reference events, and the current GraphQL rate limit. In “Only selected” mode, the repository qualifiers are part of the GitHub request itself; unselected repositories are not scanned and filtered afterward. Discovery and detail batches are committed as one snapshot, so ring colors and flyout facts cannot come from different refresh generations.

```bash
gh auth login -h github.com
```

The app refreshes the queue automatically at most once every two minutes; manual refresh bypasses that cooldown but still respects rate-limit protection. Hovering never makes an API request. A refresh has a 60-second total deadline, and each GitHub CLI subprocess also has a deadline, so “Refreshing…” cannot remain stuck indefinitely. PR Notch preserves the final 1,000 points of the authenticated account's hourly GraphQL allowance, pauses until GitHub's reported reset time when necessary, and exponentially backs off after failures. Until a live refresh succeeds, the last-known queue remains visible and each flyout reports exactly how long ago it was updated. Transient GitHub failures are retried automatically and never shown as authentication failures. Repository discovery uses a separate REST request and reuses its cache for 24 hours unless refreshed manually.

Automatic refresh combines one paginated search for authored PR IDs with live status for up to 50 cached PRs in one GraphQL request. Selected repositories are applied to discovered IDs before requesting their details; exceptionally large authored queues fall back to repository-qualified searches. New PRs and larger queues use additional bounded batches. Review-thread counts, CI, reviews, mergeability, and relationships remain live on each two-minute cycle. Comment text is cached by thread ID and count, refreshed when the PR changes, and expires after ten minutes. Required-check policies are cached once per repository for one hour. Manual refresh updates these caches immediately. The caches survive app restarts and are scoped to the authenticated account. Closed/draft PRs are removed using current state, and incomplete responses preserve the last complete queue. A timed-out combined query gets one retry using smaller requests; rate-limit failures do not trigger extra retries. Repository-filter edits are debounced into one refresh.

The rail's context menu shows PR Notch's own request count and GraphQL points for the past hour. `~/Library/Application Support/PRNotch/api-usage.json` stores the rolling request ledger, separately from GitHub's shared account quota. Failed requests with unreported GraphQL cost are recorded as unknown; their cost is not assumed to be zero. Repository-discovery pagination counts each successful HTTP page. A failed paginated REST command records at least one attempt because GitHub CLI does not report how many pages completed before failure.

Repository scope is saved both in app preferences and in Application Support so replacing the app—or changing its bundle identifier in a future release—does not reset the watched list. Repository search accepts case-insensitive regular expressions such as `frontend|worker` and performs all matching locally.

## Run

```bash
./script/build_and_run.sh --verify
```

The script builds the Swift package, stages and ad-hoc signs `dist/PRNotch.app`, installs it as `~/Applications/PRNotch.app`, and launches that installed copy through Launch Services. Set `PR_NOTCH_INSTALL_DIR` to use a different install location. Right-click the rail to refresh, copy a compact review request, open settings, or quit.

For deterministic visual QA with representative green, blue, yellow, and red PRs:

```bash
./script/build_and_run.sh --qa-expanded
```
