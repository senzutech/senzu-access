#!/usr/bin/env bash
# One-off: repository metadata and private vulnerability reporting.
set -euo pipefail
repo=senzutech/senzu-access
gh repo edit "$repo" \
  --description "Maintenance access for Senzu: a named SSH account, closed by default, open only while a paid intervention is in progress." \
  --homepage "https://senzu.tech" \
  --enable-issues --enable-wiki=false --delete-branch-on-merge \
  --add-topic ssh --add-topic sudo --add-topic managed-services --add-topic just-in-time-access \
  --add-topic hermes-agent --add-topic server-administration --add-topic security
gh api -X PUT "repos/$repo/private-vulnerability-reporting" >/dev/null
echo "configured $repo"
