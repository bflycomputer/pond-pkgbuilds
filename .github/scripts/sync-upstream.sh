#!/usr/bin/env bash
set -euo pipefail

readonly upstream_repository="${POND_UPSTREAM_REPOSITORY:-CachyOS/CachyOS-PKGBUILDS}"
readonly package_map="${POND_PACKAGE_MAP:-.github/cachyos-packages.tsv}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_path() {
  [[ "$1" =~ ^[A-Za-z0-9@._+-]+(/[A-Za-z0-9@._+-]+)*$ ]]
}

last_upstream_commit() {
  local pond_path="$1"
  local pond_commit
  local upstream_commit

  while IFS= read -r pond_commit; do
    upstream_commit="$(
      git show -s --format=%B "$pond_commit" |
        git interpret-trailers --parse |
        sed -n 's/^Upstream-Commit: //p' |
        tail -n1
    )"
    if [[ "$upstream_commit" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$upstream_commit"
      return 0
    fi
  done < <(git rev-list "origin/$branch" -- "$pond_path")

  git merge-base "origin/$branch" "$upstream_ref"
}

mapped_tree() {
  local upstream_commit="$1"
  local upstream_path="$2"
  local pond_path="$3"
  local index_file
  local tree

  index_file="$(mktemp)"
  rm -f "$index_file"
  GIT_INDEX_FILE="$index_file" git read-tree HEAD
  GIT_INDEX_FILE="$index_file" git rm -r --cached --ignore-unmatch -- "$pond_path" \
    >/dev/null

  if git cat-file -e "$upstream_commit:$upstream_path" 2>/dev/null; then
    GIT_INDEX_FILE="$index_file" \
      git read-tree --prefix="$pond_path/" "$upstream_commit:$upstream_path"
  fi

  GIT_INDEX_FILE="$index_file" git rm -r -f --cached --ignore-unmatch \
    -- ":(glob)$pond_path/**/.SRCINFO" >/dev/null

  tree="$(GIT_INDEX_FILE="$index_file" git write-tree)"
  rm -f "$index_file"
  printf '%s\n' "$tree"
}

# Only literal checksum arrays are automatic; unfamiliar shell expressions need review.
without_checksums() {
  awk '
    /^[ \t]*(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[a-zA-Z0-9_]+)?\+?=\(/ {
      name = $0; sub(/\+?=.*/, "", name); gsub(/^[ \t]+/, "", name)
      if (seen[name]++) exit 1
      print name "=(\047SKIP\047)"
      active = 1; sub(/^[^(]*\(/, "")
    }
    active {
      sub(/#.*/, "")
      end = /\)/
      gsub(/[\047\042]/, ""); gsub(/SKIP|[[:xdigit:][:space:]()]/, "")
      if (length($0)) exit 1
      if (end) active = 0
      next
    }
    { print }
    END { if (active) exit 1 }
  ' "$1"
}

pkgbuild_version() {
  (
    cd "$1" || exit 1
    env -i PATH="$PATH" HOME="$2" makepkg --printsrcinfo CARCH=x86_64
  ) | awk '
    $1 == "epoch" { epoch = $3 }
    $1 == "pkgver" { version = $3 }
    $1 == "pkgrel" { release = $3 }
    END {
      if (!version || release !~ /^[0-9]+([.][0-9]+)?$/) exit 1
      print (epoch ? epoch : 0) ":" version "-" release
    }
  '
}

merge_pkgbuild() {
  local scratch="$1" recipe="$2" directory="${2%/*}" side
  local pkgrel ours_version merged_version

  # A conflicted source file must be resolved before its checksum is calculated.
  if awk -v directory="$directory/" -v recipe="$recipe" \
    'index($0, directory) == 1 && $0 != recipe { found = 1 } END { exit !found }' \
    "$scratch/conflicts"; then
    return 1
  fi
  # Merge recipe changes independently of Pond's distribution revision.
  pkgrel="$(sed -n 's/^pkgrel=//p' "$scratch/incoming/$recipe")"
  [[ "$pkgrel" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  for side in ours base incoming; do
    without_checksums "$scratch/$side/$recipe" >"$scratch/$side.recipe" || return 1
    sed -i -E "s/^pkgrel=.*/pkgrel=$pkgrel/" "$scratch/$side.recipe" || return 1
  done
  git merge-file -p -L Pond -L base -L upstream \
    "$scratch/ours.recipe" "$scratch/base.recipe" "$scratch/incoming.recipe" \
    >"$scratch/merged/$recipe" || return 1

  ours_version="$(pkgbuild_version "$scratch/ours/$directory" "$scratch")" || return 1
  merged_version="$(pkgbuild_version "$scratch/merged/$directory" "$scratch")" || return 1
  if [[ "${ours_version%-*}" == "${merged_version%-*}" ]] &&
    (( $(vercmp "$merged_version" "$ours_version") <= 0 )); then
    pkgrel="${ours_version##*-}"
    sed -i -E "s/^pkgrel=.*/pkgrel=$pkgrel/" "$scratch/merged/$recipe" || return 1
    refresh_pkgbuild_checksums "$scratch" "$recipe" || return 1
    # An upstream revision catching up with Pond needs no rebuild by itself.
    git diff --quiet HEAD -- "$directory" && return 0
    pkgrel="$((10#${pkgrel%%.*} + 1))"
    sed -i -E "s/^pkgrel=.*/pkgrel=$pkgrel/" "$scratch/merged/$recipe" || return 1
    printf '%s: bumping pkgrel to %s for changed package content.\n' "$recipe" "$pkgrel"
  fi
  refresh_pkgbuild_checksums "$scratch" "$recipe"
}

refresh_pkgbuild_checksums() {
  local scratch="$1" recipe="$2" directory="${2%/*}"

  # makepkg downloads the sources and regenerates every checksum, without building.
  (
    cd "$scratch/merged/$directory" || exit 1
    env -i PATH="$PATH" HOME="$scratch" \
      makepkg --geninteg --nocolor CARCH=x86_64
  ) >"$scratch/checksums" || return 1
  awk -v checksums="$scratch/checksums" '
    /^[a-z0-9_]+sums(_[a-zA-Z0-9_]+)?=\(/ {
      if (!written++) while ((getline line < checksums) > 0) print line
      next
    }
    { print }
    END { if (!written) while ((getline line < checksums) > 0) print line }
  ' "$scratch/merged/$recipe" >"$scratch/result" || return 1
  cp "$scratch/result" "$recipe"
}

apply_upstream_commit() {
  local upstream_commit="$1"
  local upstream_path="$2"
  local pond_path="$3"
  local parent
  local base_tree
  local incoming_tree
  local base_commit
  local incoming_commit
  local merge_output
  local merged_tree
  local upstream_subject
  local commit_subject
  local commit_body
  local upstream_pr_number
  local merged_by
  local merge_status=0 scratch side recipe

  parent="$(git rev-parse "$upstream_commit^1")"
  base_tree="$(mapped_tree "$parent" "$upstream_path" "$pond_path")"
  incoming_tree="$(mapped_tree "$upstream_commit" "$upstream_path" "$pond_path")"
  base_commit="$(printf 'base\n' | git commit-tree "$base_tree")"
  incoming_commit="$(printf 'incoming\n' | git commit-tree "$incoming_tree")"

  merge_output="$(
    git merge-tree --write-tree --messages --name-only \
      --merge-base="$base_commit" HEAD "$incoming_commit"
  )" || merge_status=$?
  ((merge_status <= 1)) || return 1
  merged_tree="${merge_output%%$'\n'*}"
  [[ "$merged_tree" =~ ^[0-9a-f]{40,64}$ ]] || return 1

  scratch="$(mktemp -d)"
  # merge-tree provides both the conflicted tree and the paths needing resolution.
  sed '1d; /^$/,$d' <<<"$merge_output" >"$scratch/conflicts"
  for side in ours base incoming merged; do
    mkdir "$scratch/$side"
    case "$side" in
      ours) recipe=HEAD ;;
      base) recipe="$base_tree" ;;
      incoming) recipe="$incoming_tree" ;;
      merged) recipe="$merged_tree" ;;
    esac
    git archive "$recipe" -- "$pond_path" | tar -x -C "$scratch/$side" || {
      rm -rf "$scratch"
      return 1
    }
  done
  git read-tree --reset -u "$merged_tree" || { rm -rf "$scratch"; return 1; }

  while IFS= read -r recipe; do
    [[ "${recipe##*/}" == PKGBUILD ]] || continue
    [[ -f "$scratch/base/$recipe" && -f "$scratch/ours/$recipe" && -f "$recipe" ]] || continue
    git diff --quiet HEAD "$merged_tree" -- "${recipe%/*}" && continue
    if merge_pkgbuild "$scratch" "$recipe"; then
      awk -v path="$recipe" '$0 != path' "$scratch/conflicts" >"$scratch/remaining"
      mv "$scratch/remaining" "$scratch/conflicts"
    else
      printf 'Unable to merge recipe and refresh checksums for %s; including it in the PR for resolution.\n' "$recipe" >&2
      sync_review+="$recipe (checksum or recipe resolution required)"$'\n'
    fi
  done < <(git ls-tree -r --name-only "$incoming_tree" -- "$pond_path")
  while IFS= read -r recipe; do
    sync_review+="$recipe"$'\n'
  done <"$scratch/conflicts"
  rm -rf "$scratch"
  git add -A -- "$pond_path" || return 1

  upstream_subject="$(git show -s --format=%s "$upstream_commit")"
  commit_subject="$(sed -E 's/ \(#[0-9]+\)$//' <<<"$upstream_subject")"
  commit_body="Upstream-Repository: $upstream_repository
Upstream-Commit: $upstream_commit
Upstream-URL: https://redirect.github.com/$upstream_repository/commit/$upstream_commit"

  if [[ "$upstream_subject" =~ \(\#([0-9]+)\)$ ]]; then
    upstream_pr_number="${BASH_REMATCH[1]}"
    commit_body+=$'\n'"Upstream-PR: https://redirect.github.com/$upstream_repository/pull/$upstream_pr_number"
    merged_by="$(
      gh api "repos/$upstream_repository/pulls/$upstream_pr_number" \
        --jq '.merged_by.login // empty' 2>/dev/null || true
    )"
    [[ -z "$merged_by" ]] || commit_body+=$'\n'"Upstream-Merged-By: $merged_by"
  fi

  git commit --quiet --allow-empty \
    -m "$commit_subject" -m "$commit_body" || return 1

  printf 'Applied %s to %s as %s\n' \
    "$upstream_commit" "$pond_path" "$(git rev-parse HEAD)"
}

# Export the merged recipe's kernel version so patch changes appear in the PR.
refresh_kernel_patches() {
  local pond_path="$1"
  local recipe="$1/PKGBUILD"
  local tag kernel_git scratch report_file status=0

  tag="cachyos-$(sed -n 's/^_major=//p' "$recipe").$(sed -n 's/^_minor=//p' "$recipe")-$(sed -n 's/^_tagrel=//p' "$recipe")"
  [[ "$tag" =~ ^cachyos-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || {
    printf 'unexpected kernel version in %s: %s\n' "$recipe" "$tag" >&2
    return 1
  }

  # Fetch blobs on demand to avoid downloading the entire kernel tree.
  kernel_git="${POND_KERNEL_GIT_DIR:-${RUNNER_TEMP:-/tmp}/cachyos-linux.git}"
  if [[ -d "$kernel_git" ]]; then
    git --git-dir="$kernel_git" fetch --quiet --no-tags --filter=blob:none origin \
      "refs/tags/$tag:refs/tags/$tag" || return 1
  else
    git clone --quiet --bare --filter=blob:none --no-tags --single-branch --branch "$tag" \
      https://github.com/CachyOS/linux.git "$kernel_git" || return 1
  fi

  scratch="$(mktemp -d)"
  report_file="$scratch/report.md"
  python3 "$(dirname "${BASH_SOURCE[0]}")/export-kernel-patches.py" \
    --git-dir "$kernel_git" --tag "$tag" --package-dir "$pond_path" --report "$report_file" \
    --verify-base https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git || status=$?
  if ((status > 1)) || [[ ! -s "$report_file" ]]; then
    rm -rf "$scratch"
    return 1
  fi
  ((status == 0)) || sync_review+="$pond_path kernel patches (see NEEDS ATTENTION in the report below)"$'\n'
  # Leave room for the rest of the PR body within GitHub's 65,536-character limit.
  kernel_report="$(head -c 50000 "$report_file")"
  rm -rf "$scratch"

  # Patches are read from the checkout, outside makepkg's source checksums.
  git add -A -- "$pond_path/patches" || return 1
  git diff --cached --quiet || git commit --quiet -m "$pond_path: refresh CachyOS kernel patches for $tag" || return 1
}

sync_package() {
  local upstream_path="$1"
  local pond_path="$2"
  local cursor
  local branch_name
  local upstream_commit
  local pr_number
  local body_file
  local upstream_commits
  local sync_review=''
  local kernel_report=''

  cursor="$(last_upstream_commit "$pond_path")"
  git cat-file -e "$cursor^{commit}" 2>/dev/null || {
    printf 'unknown upstream cursor for %s: %s\n' "$pond_path" "$cursor" >&2
    return 1
  }
  git merge-base --is-ancestor "$cursor" "$upstream_ref" || {
    printf 'upstream cursor for %s is no longer reachable: %s\n' \
      "$pond_path" "$cursor" >&2
    return 1
  }

  if git diff --quiet "$cursor" "$upstream_ref" -- "$upstream_path"; then
    printf '%s is current at %s.\n' "$pond_path" "$cursor"
    return 0
  fi

  branch_name="bot/sync/${pond_path//\//-}"
  git check-ref-format --branch "$branch_name" >/dev/null
  pr_number="$(
    gh pr list --base "$branch" --head "$branch_name" --state open \
      --json number --jq '.[0].number // empty'
  )" || return 1
  git fetch --no-tags origin \
    "+refs/heads/$branch_name:refs/remotes/origin/$branch_name" 2>/dev/null || true
  git checkout --quiet -B "$branch_name" "origin/$branch" || return 1

  mapfile -t upstream_commits < <(
    git rev-list --reverse --first-parent \
      "$cursor..$upstream_ref" -- "$upstream_path"
  )

  for upstream_commit in "${upstream_commits[@]}"; do
    apply_upstream_commit "$upstream_commit" "$upstream_path" "$pond_path" || return 1
  done

  if [[ -f "$pond_path/patches/cachyos/rules" ]]; then
    refresh_kernel_patches "$pond_path" || return 1
  fi

  if git diff --quiet "origin/$branch" HEAD; then
    printf '%s has no resulting Pond changes.\n' "$pond_path"
    return 0
  fi

  git push --force-with-lease origin "HEAD:refs/heads/$branch_name" || return 1

  body_file="$(mktemp)"
  {
    printf 'Automated CachyOS package synchronization.\n\n'
    printf -- '- Upstream path: `%s`\n' "$upstream_path"
    printf -- '- Pond path: `%s`\n' "$pond_path"
    printf -- '- Previous upstream commit: `%s`\n' "$cursor"
    printf -- '- Current upstream commit: `%s`\n' "$(git rev-parse "$upstream_ref")"
    if [[ -n "$sync_review" ]]; then
      printf '\nSome changes need conflict resolution or checksum regeneration:\n\n'
      printf '%s' "$sync_review" | sort -u | sed 's/^/- /'
    fi
    if [[ -n "$kernel_report" ]]; then
      printf '\n%s\n' "$kernel_report"
    fi
  } >"$body_file"

  if [[ -n "$pr_number" ]]; then
    gh pr edit "$pr_number" \
      --title "$pond_path: sync CachyOS updates" \
      --body-file "$body_file" || { rm -f "$body_file"; return 1; }
  else
    gh pr create \
      --base "$branch" \
      --head "$branch_name" \
      --title "$pond_path: sync CachyOS updates" \
      --body-file "$body_file" || { rm -f "$body_file"; return 1; }
  fi

  rm -f "$body_file"
}

if (($# != 1)); then
  printf 'usage: sync-upstream.sh <upstream-master-ref>\n' >&2
  exit 2
fi

upstream_ref="$1"
branch="${POND_BRANCH:-main}"

[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required'
[[ -f "$package_map" ]] || die "missing package map: $package_map"
git cat-file -e "$upstream_ref^{commit}" 2>/dev/null || \
  die "unknown upstream ref: $upstream_ref"

git fetch --no-tags origin "$branch"
git checkout --quiet -B "$branch" "origin/$branch"
[[ -z "$(git status --porcelain)" ]] || die 'Pond checkout is not clean'

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git config commit.gpgSign false

upstream_paths=()
pond_paths=()
declare -A seen_upstream=()
declare -A seen_pond=()

while IFS=$'\t' read -r upstream_path pond_path; do
  [[ -n "$upstream_path" && -n "$pond_path" ]] || \
    die 'package map contains an incomplete row'
  valid_path "$upstream_path" || die "unsafe upstream path: $upstream_path"
  valid_path "$pond_path" || die "unsafe Pond path: $pond_path"
  [[ -z "${seen_upstream[$upstream_path]:-}" ]] || \
    die "duplicate upstream path: $upstream_path"
  [[ -z "${seen_pond[$pond_path]:-}" ]] || \
    die "duplicate Pond path: $pond_path"
  git cat-file -e "$upstream_ref:$upstream_path" 2>/dev/null || \
    die "upstream package path does not exist: $upstream_path"
  [[ -e "$pond_path" ]] || die "Pond package path does not exist: $pond_path"

  seen_upstream["$upstream_path"]=1
  seen_pond["$pond_path"]=1
  upstream_paths+=("$upstream_path")
  pond_paths+=("$pond_path")
done <"$package_map"

failures=()
for index in "${!upstream_paths[@]}"; do
  git checkout --quiet -B "$branch" "origin/$branch"
  if ! sync_package "${upstream_paths[$index]}" "${pond_paths[$index]}"; then
    failures+=("${pond_paths[$index]}")
    git read-tree --reset -u HEAD
  fi
done

git checkout --quiet -B "$branch" "origin/$branch"

if (("${#failures[@]}" > 0)); then
  printf 'error: failed to synchronize: %s\n' "${failures[*]}" >&2
  exit 1
fi

printf 'Checked %s CachyOS package group(s).\n' "${#upstream_paths[@]}"
