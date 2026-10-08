#!/bin/bash

# NOTE: this file refs to https://github.com/line/headver/blob/main/examples/bash.md.

# Fail loudly. Before this, `git tag` could fail with "tag already exists" and the step still
# went green, because `git push` ran last and its exit status was the script's -- so a release
# that was never tagged reported success. See the tag-collision guard near the bottom.
set -euo pipefail

version=""
yearweek=""
override_version=""
# Assigned only on the computed path; the collision message below reads it on both, and an
# unbound read is fatal under `set -u`.
lastest=""
# Empty means "now". Set via --forced_date to pin the clock -- the only way to exercise the
# two year-boundary corrections below, which otherwise fire about two weeks a year.
forced_date=""

# sanitize inputs
for ARGUMENT in "$@"
do
    KEY=$(echo $ARGUMENT | cut -f1 -d=)
    VALUE=$(echo $ARGUMENT | cut -f2 -d=)

    case "$KEY" in
            --override_version)
              override_version=${VALUE} ;;

            --forced_date)
              forced_date=${VALUE} ;;

            *)
              echo "ERROR: unknown parameter \"$KEY\""
              exit 1 ;;
    esac
done

# All three components come from ONE reading of the clock so they cannot disagree with each
# other (year from one instant and week from the next, across a midnight, would be a silent
# wrong tag). `date -d` is GNU-only and is used solely on the injected path; the default path
# stays portable.
if [ -n "${forced_date}" ]; then
    year=$(date -d "${forced_date}" +%Y)
    weeknumber=$(date -d "${forced_date}" +%V)  # ISO Standard week number
    day=$(date -d "${forced_date}" +%-d)
else
    year=$(date +%Y)
    weeknumber=$(date +%V)  # ISO Standard week number
    day=$(date +%-d)
fi

echo "fetching latest tags from remote...";
# Two different things both make the fetch below exit 1: a remote with no tags yet (the
# refspec matches nothing -- git reports this as exit 1 with NO message), and a real failure
# such as a bad token or an unreachable host. They must NOT be treated the same.
#
# Blanket-tolerating the fetch recreates the bug this script exists to fix: with the fetch
# failed there are zero local tags, so `lastest` is empty and the version computes to
# $head.$yearweek.0. The collision guard below cannot catch that, because `git rev-parse`
# consults only LOCAL refs and there are none. The push usually then gets rejected -- loud,
# fine -- but if the remote's $head.$yearweek.0 already points at this commit, the push is a
# no-op that prints "Everything up-to-date" and exits 0, and the script reports `tagged`
# having created nothing. That is precisely the original failure.
#
# `git ls-remote` separates the cases cleanly: exit 0 against a reachable tagless remote,
# 128 against an unreachable one.
remote_tags=$(git ls-remote --tags origin) || {
    echo "ERROR: cannot reach origin to list tags. Refusing to compute a version from an"
    echo "       incomplete tag list -- that is how a taken version gets recomputed."
    exit 1
}

if [ -z "${remote_tags}" ]; then
    echo "- Warning: remote has no tags yet; this run will create the first."
else
    # Tags exist, so a failure here IS a failure: let `set -e` stop the run.
    git fetch --depth=1 origin '+refs/tags/*:refs/tags/*'
fi

# this prevents from having 1801 at the last week of the year 2019. It should be 1901.
# ${day} is today, from the same clock as ${year}/${weeknumber} above. This used to read
# `date -u -d ${forced_date}` while ${forced_date} was assigned nowhere, so the substitution
# errored and both year corrections silently never applied.
if [ ${weeknumber} -eq 1 ] && [ ${day} -gt 20 ]; then
  year=$(expr ${year} + 1)
fi

# this prevents from having 1053 at the last week of the year 2010. It should be 0953.
if [ ${weeknumber} -ge 52 ] && [ ${day} -le 7 ]; then
    year=$(expr ${year} - 1)
fi

yearweek="${year:2:2}${weeknumber}"

if [ -z "${override_version}" ]; then
    # `|| true` because under `pipefail` a package.json with no headVersion key makes grep
    # exit 1 and takes the whole script with it, printing nothing at all. Checked explicitly
    # below instead, so the reason is on screen.
    head=$(grep -m 1 headVersion ./package.json 2>/dev/null | sed 's/[^0-9.]//g') || true

    if [ -z "${head}" ]; then
        echo "ERROR: no headVersion found in ./package.json -- cannot compute a version."
        exit 1
    fi

    printf "current the calver headVersion pasred from package.json: $head\n"

    # Sort by VERSION, not by committer date. `--sort=committerdate` reads a field that only
    # exists on lightweight tags; an annotated tag (which is what a GitHub Release creates)
    # has no committerdate, sorts to the FRONT, and `tail -1` then returns the wrong "latest".
    # That is not hypothetical: mediacat.xl8.ai had exactly one annotated tag out of 895
    # (2.2641.1), which pinned "latest" at 2.2641.0 and made every subsequent run recompute
    # the same already-taken 2.2641.1 forever. `v:refname` is refname-only, so it is immune to
    # tag object type, and it orders .10 after .9 (a plain lexical sort does not).
    lastest=`git tag --sort=v:refname | grep -E '^[0-9]' | tail -1 || true`
    latestHead=`echo $lastest | cut -d. -f1`
    latestYearweek=`echo $lastest | cut -d. -f2`
    latestBuild=`echo $lastest | cut -d. -f3`

    printf "lastHead: $latestHead\n"
    printf "lastYearweek: $latestYearweek\n"
    printf "lastBuild: $latestBuild\n"

    printf "latest $latestHead.$latestYearweek.$latestBuild\n"

    if [ -z "${lastest}" ]; then
        build="0"
        echo "- Warning: There is no tag. set to default.";
    else
        if [ -z "${latestBuild}" ]; then
            build="0"
            echo "- Warning: no build value. set to 0 by default."
        else
            build=$(($latestBuild + 1))
        fi

        if [ "$yearweek" != "$latestYearweek" ]; then
            build="0"
            echo "- Warning: yearweek is changed"
        fi
    fi

    version="$head.$yearweek.$build"
else
    echo "- Warning: head, build, suffix values will be ignored"
    version=${override_version}
fi

printf "version: $version\n"

# Refuse to report success without tagging. If this ever fires, the computed version is
# already taken and the run needs a human -- silently exiting 0 here is what hid the bug.
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "ERROR: tag '$version' already exists. Refusing to report success without tagging."
    echo "       Latest tag seen was '${lastest:-n/a (override_version was used)}' (version-sorted)."
    exit 1
fi

git tag "$version"
# Push THIS tag, not --tags: --tags pushes every local tag, which can resurrect ones that
# were deliberately deleted on the remote.
git push origin "refs/tags/$version"
echo "tagged $version"
