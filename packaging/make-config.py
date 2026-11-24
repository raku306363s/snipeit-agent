"""Writes config.json for the installers from environment variables.
SNIPEIT_URL and SNIPEIT_AGENT_TOKEN come from GitHub Actions secrets."""
import json, os, sys
url = os.environ.get("SNIPEIT_URL", "").strip().rstrip("/")
token = "".join(os.environ.get("SNIPEIT_AGENT_TOKEN", "").split())
if not url or len(token) < 100:
    sys.exit("SNIPEIT_URL / SNIPEIT_AGENT_TOKEN secrets are missing or the token looks truncated "
             "(%d chars). Add them under Settings > Environments." % len(token))
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"SnipeUrl": url, "ApiToken": token, "HeartbeatDays": 7, "MaxSoftwareChars": 60000, "AssetTag": ""}, f, indent=2)
print("config.json written for %s (token %d chars)" % (url, len(token)))
