#!/usr/bin/env bash
# Works out, or checks, an add-on chart's version from the repo's GitHub
# Releases. See this action's action.yml for what each mode is for.
#
#   chart-version.sh derive   print the dev chart version for this push's branch
#   chart-version.sh check    fail unless a release/pre-release dispatch's
#                             version is safe to publish
#
# Inputs come from the environment (action.yml maps them): REPO, REF_NAME,
# CHART_PATH, DEV_REGISTRY, RELEASE_REGISTRY, plus VERSION_INPUT and
# PRE_RELEASE_INPUT for `check`. Needs gh (with GH_TOKEN), helm and yq.
set -euo pipefail

: "${REPO:?}" "${REF_NAME:?}" "${CHART_PATH:?}" "${DEV_REGISTRY:?}" "${RELEASE_REGISTRY:?}"

readonly PRE_RELEASE_ANNOTATION='dev-charts.portainer.io/pre-release'
readonly SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

err() {
  echo "::error::$*" >&2
  exit 1
}

notice() { echo "::notice::$*" >&2; }

chart_name() {
  local name
  name=$(yq -r '.name // ""' "${CHART_PATH%/}/Chart.yaml")
  [ -n "$name" ] || err "no name: field in ${CHART_PATH%/}/Chart.yaml"
  printf '%s\n' "$name"
}

# Every published (non-draft) release tag that is plain X.Y.Z once a leading
# "v" is stripped, sorted ascending. Pre-release-flagged GitHub Releases
# count too: they still claimed that version number.
list_releases() {
  local tags
  tags=$(gh api "repos/$REPO/releases" --paginate --jq '.[] | select(.draft | not) | .tag_name') ||
    err "could not list GitHub Releases for $REPO"
  printf '%s\n' "$tags" | sed 's/^v//' | { grep -E "$SEMVER" || true; } | sort -V
}

# The X.Y of every release/X.Y branch, sorted ascending.
list_release_branch_lines() {
  local branches
  branches=$(gh api "repos/$REPO/branches" --paginate --jq '.[].name') ||
    err "could not list branches for $REPO"
  printf '%s\n' "$branches" | sed -nE 's#^release/([0-9]+\.[0-9]+)$#\1#p' | sort -V
}

# Highest release in line $1 (X.Y), or empty.
highest_in_line() {
  printf '%s\n' "$RELEASES" | { grep -E "^${1//./\\.}\.[0-9]+$" || true; } | tail -1
}

bump_patch() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  echo "$major.$minor.$((patch + 1))"
}

# True when $1 is strictly higher than $2 (both X.Y.Z or both X.Y).
is_higher() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# Prints the Chart.yaml of <registry>/<name>:<version> and returns 0 when it
# exists, returns 1 when it doesn't, and 2 on any other failure (network,
# auth), so a lookup error is never mistaken for "not published".
# Anonymous: both chart registries are public.
chart_meta() {
  local out errfile
  errfile=$(mktemp)
  if out=$(helm show chart "$1/$2" --version "$3" 2>"$errfile"); then
    rm -f "$errfile"
    # helm prints its own "Pulled:"/"Digest:" lines to stdout for OCI charts.
    printf '%s\n' "$out" | sed -E '/^(Pulled|Digest): /d'
    return 0
  fi
  if grep -q ': not found' "$errfile"; then
    rm -f "$errfile"
    return 1
  fi
  cat "$errfile" >&2
  rm -f "$errfile"
  return 2
}

derive() {
  local name line highest version source
  name=$(chart_name)

  if [[ "$REF_NAME" =~ ^release/([0-9]+\.[0-9]+)$ ]]; then
    line=${BASH_REMATCH[1]}
    highest=$(highest_in_line "$line")
    if [ -n "$highest" ]; then
      version=$(bump_patch "$highest")
      source="the next patch after $highest, the highest release in $line"
    else
      version="$line.0"
      source="the first version of $line, which has no release yet"
    fi
  elif [[ "$REF_NAME" == release/* ]]; then
    err "branch '$REF_NAME' isn't release/X.Y, so no dev chart version can be derived for it"
  else
    local branch_lines top_line top_release
    branch_lines=$(list_release_branch_lines)
    top_release=$(printf '%s\n' "$RELEASES" | tail -1)
    if [ -n "$branch_lines" ]; then
      # The highest line across release branches AND releases: a release
      # branch may be deleted after its line shipped.
      top_line=$(printf '%s\n%s\n' "$branch_lines" "${top_release%.*}" | sed '/^$/d' | sort -V | tail -1)
      version="${top_line%.*}.$((${top_line#*.} + 1)).0"
      source="the next minor after $top_line, the highest release line"
    elif [ -n "$top_release" ]; then
      version=$(bump_patch "$top_release")
      source="the next patch after $top_release, the latest release (no release/* branches)"
    else
      version=$(yq -r '.version // ""' "${CHART_PATH%/}/Chart.yaml")
      source="${CHART_PATH%/}/Chart.yaml, since $REPO has no release or release branch yet"
    fi
  fi

  [[ "$version" =~ $SEMVER ]] || err "derived dev chart version '$version' isn't plain X.Y.Z (from $source)"

  # A pre-release claims its version in dev-charts until a real release
  # moves past it, so step over any the branch would otherwise overwrite.
  local meta rc steps=0
  while :; do
    set +e
    meta=$(chart_meta "$DEV_REGISTRY" "$name" "$version")
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && err "could not look up $DEV_REGISTRY/$name:$version"
    [ "$rc" -eq 1 ] && break
    [ "$(printf '%s\n' "$meta" | yq -r ".annotations[\"$PRE_RELEASE_ANNOTATION\"] // \"\"")" = "true" ] || break
    notice "$DEV_REGISTRY/$name:$version is a pre-release; not overwriting it"
    version=$(bump_patch "$version")
    steps=$((steps + 1))
    [ "$steps" -lt 50 ] || err "stepped past 50 pre-release versions from $source; something is wrong"
  done

  notice "dev chart version $version ($source$([ "$steps" -gt 0 ] && echo ", stepping past $steps pre-release(s)"))"
  printf '%s\n' "$version"
}

check() {
  local name version line highest kind
  [ -n "${VERSION_INPUT:-}" ] ||
    err "no 'version' input on this workflow_dispatch; the calling release.yml must define 'version' and 'pre-release' inputs (see the README)"
  case "${PRE_RELEASE_INPUT:-}" in
    true) kind="pre-release" ;;
    false) kind="release" ;;
    *) err "the 'pre-release' input on this workflow_dispatch is missing or not a boolean (got '${PRE_RELEASE_INPUT:-}'); see the README" ;;
  esac

  version=${VERSION_INPUT#v}
  [[ "$version" =~ $SEMVER ]] || err "version '$VERSION_INPUT' isn't plain X.Y.Z (a leading v is allowed)"
  line=${version%.*}
  name=$(chart_name)

  if [[ "$REF_NAME" =~ ^release/([0-9]+\.[0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" != "$line" ]; then
    err "$version isn't on the ${BASH_REMATCH[1]} line, but this was dispatched from $REF_NAME"
  fi

  highest=$(highest_in_line "$line")
  if [ -n "$highest" ] && ! is_higher "$version" "$highest"; then
    err "$version isn't higher than $highest, the highest release in $line; a $kind must move its line forward"
  fi

  if [ "$kind" = "release" ]; then
    local tag rc
    for tag in "$version" "v$version"; do
      if gh api "repos/$REPO/releases/tags/$tag" --silent 2>/dev/null; then
        err "GitHub Release $tag already exists"
      fi
    done
    set +e
    chart_meta "$RELEASE_REGISTRY" "$name" "$version" >/dev/null
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && err "could not look up $RELEASE_REGISTRY/$name:$version"
    [ "$rc" -eq 0 ] && err "$RELEASE_REGISTRY/$name:$version is already published; a release can't be published twice"
  fi

  notice "$kind $version is safe to publish (line $line, highest release there: ${highest:-none})"
}

RELEASES=$(list_releases)

case "${1:-}" in
  derive) derive ;;
  check) check ;;
  *) err "usage: chart-version.sh derive|check" ;;
esac
