#!/bin/bash
# Compile the offline guide trial using shipping value types/parser/helpers.
# --tests builds and runs standalone regressions; no simulator or app build.
# --validate runs the adversarial promotion gate (nonzero until rules are safe).
set -euo pipefail
cd "$(dirname "$0")/.."

trial_entrypoint=Scripts/epg-enrichment-trial.swift
trial_output=.build/epg-enrichment-trial
case "${1:-}" in
  "") ;;
  --tests)
    trial_entrypoint=Scripts/epg-sports-trial-tests.swift
    trial_output=.build/epg-sports-trial-tests
    ;;
  --validate)
    trial_entrypoint=Scripts/epg-sports-validation-probes.swift
    trial_output=.build/epg-sports-validation-probes
    ;;
  *) echo "Usage: bash Scripts/build-epg-trial.sh [--tests|--validate]" >&2; exit 2 ;;
esac
mkdir -p .build
swiftc -O -swift-version 5 -default-isolation MainActor \
  Lume/Services/Network/XMLTVDate.swift \
  Lume/Services/Network/XMLTVParser.swift Lume/Utils/GzipFile.swift \
  Lume/Models/EPGListing.swift \
  Lume/Services/Sync/EPGProgrammeEnrichment.swift \
  Lume/Services/Sync/EPGEnrichmentStations.swift \
  Lume/Services/Sync/EPGEnrichmentStations+UK.swift \
  Lume/Services/Sync/EPGEnrichmentCache.swift \
  Lume/Services/Sync/EPGEnrichmentFeed.swift \
  Lume/Services/Sports/SportsModels.swift \
  Lume/Services/Sports/SportsTennis.swift \
  Lume/Services/Sports/SportsMatcher.swift \
  Scripts/EPGSportsProgrammeIdentity.swift \
  Scripts/EPGSportsProgrammeTrial.swift \
  "$trial_entrypoint" -o "$trial_output"
if [[ "${1:-}" == --tests || "${1:-}" == --validate ]]; then
  "$trial_output"
fi
