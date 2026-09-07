# Shared runtime/source manifest; hash paths relative to this tool, independent of checkout location.
RUNTIME_FILES=(quota_fetch.py diagnostics.py status_logs.py status_proxy.py status_engine.py status_dns.py)
source_hash() {
  (cd "$SCRIPT_DIR"; shasum -a 256 app/*.swift "${RUNTIME_FILES[@]}" | shasum -a 256 | awk '{print $1}')
}
