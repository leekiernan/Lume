#!/bin/bash

cp ../../../Lume/.env .env
cp -R ../../../Lume/.claude/ .claude/
./Scripts/setup.sh
# Private DerivedData per worktree: without it this build shares Xcode's own
# DerivedData for the project, which can disrupt an open Xcode session.
# Pair it with the shared package clone (see CLAUDE.md) so each dir does not
# re-clone the 6.4 GB package graph.
DD="/tmp/lume-dd-$(basename "$PWD")"
# Pin the architecture to avoid also compiling x86_64 on an Apple Silicon host.
xcodebuild build -scheme Lume -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM -quiet
