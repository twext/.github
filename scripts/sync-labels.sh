#!/usr/bin/env bash
# Sync labels from labels.yml to every repository in a GitHub organization.
#
# Usage:   ./scripts/sync-labels.sh <org> [labels.yml]
# Needs:   gh (authenticated via GH_TOKEN), jq, yq (mikefarah)
#
# Env vars:
#   DRY_RUN=true        Print changes without applying them
#   PRUNE=true          Delete labels not listed in labels.yml (removes them from issues!)
#   EXCLUDE="a b c"     Space-separated repo names to skip
#   INCLUDE_FORKS=true  Also sync forks (skipped by default; archived repos are always skipped)

set -euo pipefail

ORG="${1:?Usage: sync-labels.sh <org> [labels.yml]}"
FILE="${2:-labels.yml}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE="${PRUNE:-false}"
EXCLUDE="${EXCLUDE:-}"
INCLUDE_FORKS="${INCLUDE_FORKS:-false}"
FAILED=0

# Run a mutating command, or just print it in dry-run mode.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] $*"
    return 0
  fi
  if ! "$@"; then
    echo "    ! failed: $*" >&2
    FAILED=1
  fi
  sleep 0.3 # stay clear of secondary rate limits
}

LABELS=$(yq -o=json '.labels' "$FILE")
RENAMES=$(yq -o=json '.renames // {}' "$FILE")
WANT_NAMES=$(jq -c '[.[].name | ascii_downcase]' <<<"$LABELS")

list_args=(--limit 1000 --no-archived --json name -q '.[].name')
[[ "$INCLUDE_FORKS" == "true" ]] || list_args+=(--source)
mapfile -t REPOS < <(gh repo list "$ORG" "${list_args[@]}")

echo "Syncing $(jq length <<<"$LABELS") labels to ${#REPOS[@]} repositories in $ORG (dry-run=$DRY_RUN, prune=$PRUNE)"

for name in "${REPOS[@]}"; do
  if [[ " $EXCLUDE " == *" $name "* ]]; then
    echo "== $ORG/$name (skipped)"
    continue
  fi

  repo="$ORG/$name"
  echo "== $repo"

  if ! existing=$(gh label list --repo "$repo" --limit 1000 --json name,color,description); then
    echo "  ! could not list labels (token access?)" >&2
    FAILED=1
    continue
  fi

  # 1. Rename legacy labels so issues keep them (e.g. bug -> type: bug)
  while IFS=$'\t' read -r old new; do
    [[ -z "$old" ]] && continue
    has_old=$(jq --arg n "$old" 'any(.[]; (.name | ascii_downcase) == ($n | ascii_downcase))' <<<"$existing")
    has_new=$(jq --arg n "$new" 'any(.[]; (.name | ascii_downcase) == ($n | ascii_downcase))' <<<"$existing")
    if [[ "$has_old" == "true" && "$has_new" == "false" ]]; then
      echo "  > rename: $old -> $new"
      run gh label edit "$old" --name "$new" --repo "$repo"
      existing=$(jq --arg o "$old" --arg n "$new" \
        'map(if (.name | ascii_downcase) == ($o | ascii_downcase) then .name = $n else . end)' <<<"$existing")
    fi
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$RENAMES")

  # 2. Create or update desired labels
  while IFS=$'\t' read -r lname color desc; do
    cur=$(jq -c --arg n "$lname" \
      'first(.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))) // empty' <<<"$existing")

    if [[ -z "$cur" ]]; then
      echo "  + create: $lname"
      run gh label create "$lname" --color "$color" --description "$desc" --repo "$repo"
    else
      cur_name=$(jq -r '.name' <<<"$cur")
      cur_color=$(jq -r '.color' <<<"$cur")
      cur_desc=$(jq -r '.description // ""' <<<"$cur")
      if [[ "$cur_name" != "$lname" || "${cur_color,,}" != "${color,,}" || "$cur_desc" != "$desc" ]]; then
        echo "  ~ update: $lname"
        run gh label edit "$cur_name" --name "$lname" --color "$color" --description "$desc" --repo "$repo"
      fi
    fi
  done < <(jq -r '.[] | [.name, .color, .description] | @tsv' <<<"$LABELS")

  # 3. Optionally delete labels that aren't in labels.yml
  if [[ "$PRUNE" == "true" ]]; then
    while IFS= read -r extra; do
      [[ -z "$extra" ]] && continue
      echo "  - delete: $extra"
      run gh label delete "$extra" --yes --repo "$repo"
    done < <(jq -r --argjson want "$WANT_NAMES" \
      '.[] | select((.name | ascii_downcase) as $n | ($want | index($n)) == null) | .name' <<<"$existing")
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "Finished with errors." >&2
  exit 1
fi
echo "Done."