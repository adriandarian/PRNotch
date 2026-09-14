# PR Notch visual QA

Visual QA must use the app's fictional preview fixtures. Do not capture live GitHub data, repository names, pull-request numbers, reviewer identities, desktop contents, display details, or other machine-specific state in repository artifacts.

## Safe workflow

1. Run `./script/build_and_run.sh --qa-expanded`.
2. Verify the rail, flyout, hover, click, accessibility, and relationship states using the built-in `example/*`, `acme/*`, and `DEMO-*` fixtures.
3. Keep screenshots and generated concepts outside the repository unless every visible value and metadata field has been audited as fictional and non-identifying.
4. Run `./script/release_audit.sh` before committing or publishing.

## Required fidelity surfaces

- Geometry: preserve the defined rail width, row hit area, ring diameter, and vertical stride.
- Color: show pull-request state as thin semantic rings around dark centers.
- Typography: display pull-request numbers in white SF Rounded semibold with monospaced digits and digit-aware sizing.
- Content: keep the queue as one continuous PR-state column.
- Interaction: preserve hover preview, click selection, help text, and accessibility labels.
