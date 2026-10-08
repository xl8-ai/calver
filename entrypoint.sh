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
# A tagless remote makes this refspec match nothing, which git reports as exit 1 WITH NO
# MESSAGE. Under `set -e` that killed the script here with no diagnostic at all -- the exact
# silent failure this script was changed to stop doing -- and made the "there is no tag"
# branch below unreachable, so a repo adopting this action could never cut its first tag.
git fetch --depth=1 origin '+refs/tags/*:refs/tags/*' \
    || echo "- Warning: fetched no tags (remote may have none yet)."

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
    head=$(grep -m 1 headVersion ./package.json | sed 's/[^0-9.]//g')

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
