#!/bin/bash
# Task-local cache cleanup only; never sweep shared temporary directories.
# Usage: Scripts/cleanup.sh [--apply] /private/tmp/lume-dd-<task> [...]
# Also accepts /private/tmp/lume-<task>-tests.<token>/.build.
set -euo pipefail

apply=0
targets=()
usage() {
  echo 'Usage: Scripts/cleanup.sh [--apply] <Lume task-cache path> [...]'
  echo 'Default: preview. Allowed: /{private/}tmp/lume-dd-<task> and lume-<task>-tests.<token>/.build.'
}
reject() { echo "Refusing cleanup: $1" >&2; exit 2; }

for argument in "$@"; do
  case "$argument" in
    --apply) apply=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) reject "unknown option $argument" ;;
    *) targets+=("$argument") ;;
  esac
done
if [ "${#targets[@]}" -eq 0 ]; then usage; exit 2; fi

# Validate ALL targets before acting, so a rejected second target cannot follow
# an already-deleted first one. No glob expansion or recursive root cleanup.
validated=()
for target in "${targets[@]}"; do
  case "$target" in
    /tmp/*) target="/private/tmp/${target#/tmp/}" ;;
    /private/tmp/*) ;;
    *) reject "target is outside the temporary cache namespace: $target" ;;
  esac
  relative="${target#/private/tmp/}"
  if [[ "$relative" =~ ^lume-dd-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    parent=/private/tmp
  elif [[ "$relative" =~ ^lume-[A-Za-z0-9_-]+-tests\.[A-Za-z0-9]+/\.build$ ]]; then
    parent="${target%/.build}"
    [ ! -L "$parent" ] || reject "symlink parent: $parent"
  else
    reject "not an explicitly supported task cache: $target"
  fi
  [ ! -L "$target" ] || reject "symlink target: $target"
  if [ -e "$target" ]; then
    [ -d "$target" ] || reject "not a directory: $target"
    physical_parent="$(cd "$parent" && pwd -P)"
    [ "$physical_parent" = "$parent" ] || reject "redirected parent: $parent"
  fi
  validated+=("$target")
done

# Even valid DerivedData belongs to a live build until xcodebuild exits.
if [ "$apply" -eq 1 ]; then
  if /usr/bin/pgrep -x xcodebuild >/dev/null 2>&1; then
    reject 'xcodebuild is running; try again after the build finishes'
  else
    process_status=$?
    [ "$process_status" -eq 1 ] || reject 'cannot inspect running builds; no caches deleted'
  fi
fi
for target in "${validated[@]}"; do
  if [ ! -e "$target" ]; then
    echo "Already absent: $target"
  elif [ "$apply" -eq 1 ]; then
    /bin/rm -rf -- "$target"
    echo "Removed regenerable cache: $target"
  else
    echo "Would remove: $target"
  fi
done
