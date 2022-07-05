#!/bin/sh
# NOTE: this file is made by https://github.com/line/headver/blob/main/examples/bash.md.

version=""
yearweek=""
year=`date +%Y`
weeknumber=`date +%V` # ISO Standard week number

# sanitize inputs
for ARGUMENT in "$@"
do
    KEY=$(echo $ARGUMENT | cut -f1 -d=)
    VALUE=$(echo $ARGUMENT | cut -f2 -d=)  

    case "$KEY" in
            --override_version)     
              override_version=${VALUE} ;;

            *)
              echo "ERROR: unknown parameter \"$KEY\""
              exit 1 ;;
    esac
done

echo "fetching latest tags from remote...";
git fetch --depth=1 origin +refs/tags/*:refs/tags/*

# this prevents from having 1801 at the last week of the year 2019. It should be 1901.
if [[ ${weeknumber} -eq 1 ]] && [[ `date -u -d ${forced_date} +%-d` -gt 20 ]]; then
  year=$(expr ${year} + 1)
fi

# this prevents from having 1053 at the last week of the year 2010. It should be 0953.
if [[ ${weeknumber} -ge 52 ]] && [[ `date -u -d ${forced_date} +%-d` -le 7 ]]; then
    year=$(expr ${year} - 1)
fi

yearweek="${year:2:2}${weeknumber}"

if [ -z ${override_version} ]; then
    head=$(cat package.json \
      | grep version \
      | head -1 \
      | awk -F: '{ print $2 }' \
      | sed 's/[",]//g')

    printf "current the calver head version pasred from package.json: $head\n"

    lastest=`git tag | grep "staging*" | sort -g | tail -1`
    latestHead=`echo $lastest | cut -d. -f1`
    latestCutHead=${latestHead/staging-/}
    latestYearweek=`echo $lastest | cut -d. -f2`
    latestBuild=`echo $lastest | cut -d. -f3`

    printf "lastHead: $latestCutHead $h\n"
    printf "lastYearweek: $latestYearweek\n"
    printf "lastBuild: $latestBuild\n"

    printf "latest $latestCutHead.$latestYearweek.$latestBuild\n"

    if [ -z ${lastest} ]; then
        build="0"
        echo "- Warning: There is no tag. set to default.";
    else
        if [ -z ${latestBuild} ]; then
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

git tag "staging-$version"
git push origin --tags
