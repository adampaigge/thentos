#!/bin/bash

set -o errexit
cd "$( dirname "${BASH_SOURCE[0]}" )"

export PATH=`pwd`/node_modules/.bin/:$PATH

case "$1" in
    "dep")
        echo -n 'node: ';  node  --version
        echo -n 'npm: ';   npm   --version
        time npm install
        echo -n 'bower: '; bower --version
        echo -n 'gulp: ';  gulp  --version
        echo -n 'psc: ';   psc   --version
        time bower install
        ;;
    "it")
        time gulp bundle
        ;;
    "watch")
        gulp watch
        ;;
    "generate-translation-tables")
        test -e ../.cabal-sandbox/bin/refresh-i18n \
            || echo "refresh-i18n not found.  install cabal package?"
        ../.cabal-sandbox/bin/refresh-i18n
        ;;
    "clean")
        rm -rf ./.tmp ./output ./dist ./static/thentos.js
        ;;
    "distclean")
        $0 clean
        rm -rf ./bower_components ./node_modules
        ;;
    "pull-cache")
        test "$2" == "" && ( echo "$0: please specify cache path."; exit 1 )
        echo "pulling build cache from $2..."
        rsync -a --delete "$2"/bower_components . || true
        rsync -a --delete "$2"/node_modules .     || true
        ;;
    "push-cache")
        test "$2" == "" && ( echo "$0: please specify cache path."; exit 1 )
        echo "pushing build cache to $2..."
        mkdir -p "$2"
        rsync -a --delete bower_components "$2"
        rsync -a --delete node_modules "$2"
        ;;
    *)
        echo "usage: $0 [dep|it|watch|generate-translation-tables|clean|distclean|pull-cache|push-cache]" >&2
        exit 1
        ;;
esac
