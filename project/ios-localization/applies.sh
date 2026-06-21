#!/usr/bin/env bash
# Applicable in iOS app repos: an Xcode project or an XcodeGen manifest.
cd "$1" || exit 1
[ -f project.yml ] && exit 0
ls -d *.xcodeproj >/dev/null 2>&1 && exit 0
exit 1
