#!/usr/bin/env bash

declare -a SITES
if [ "$#" -eq 0 ]; then
  SITES=( typeable.io blog.typeable.io )
else
  SITES=( "$@" )
fi

for site in "${SITES[@]}"; do
  rsync -av --delete "$site"/ root@typeable.io:/var/www/"$site"
done
