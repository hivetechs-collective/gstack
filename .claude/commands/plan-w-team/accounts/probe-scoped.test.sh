#!/usr/bin/env bash
# probe-scoped.test.sh — model-scoped (Fable) usage in the account gauges + status table.
# Sandboxed: XDG_CONFIG_HOME + PLAN_USAGE_CACHE_DIR point into a temp dir; no network
# (PWT_ACCT_SCOPED_PROBE unset ⇒ the direct GET never fires; header probes are mocked).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; NOTES=()
ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); NOTES+=("$1"); printf "  \033[31m✗\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; }
SB=$(mktemp -d -t probe-scoped-test.XXXXXX); trap 'rm -rf "$SB"' EXIT
export XDG_CONFIG_HOME="$SB/xdg" PLAN_USAGE_CACHE_DIR="$SB/plan-usage" HOME="$SB/home"
unset PWT_ACCT_SCOPED_PROBE PWT_ACCT_SCOPED_TTL PWT_ACCT_USAGE_TTL
mkdir -p "$XDG_CONFIG_HOME/claude-pwt" "$PLAN_USAGE_CACHE_DIR" "$HOME"; chmod 700 "$XDG_CONFIG_HOME/claude-pwt"
NOW=$(date +%s)
# plan-usage.sh samples: knox has an old and a newer sample; ministry a 26h-old one.
sample() { # file email fetched_at fable_pct
  printf '{"limits":[{"kind":"session","percent":5},{"kind":"weekly_all","percent":50},{"kind":"weekly_scoped","percent":%s,"scope":{"model":{"display_name":"Fable"}}}],"_meta":{"account_email":"%s","fetched_at":%s}}' "$4" "$2" "$3" > "$PLAN_USAGE_CACHE_DIR/$1.json"
}
sample aaaa knox@example.com $((NOW-3000)) 40
sample bbbb knox@example.com $((NOW-60)) 86
sample cccc ministry@example.com $((NOW-93600)) 34
echo '{"not":"json' > "$PLAN_USAGE_CACHE_DIR/dddd.json"
printf '{"version":1,"multi_account_enabled":true,"onboarding_answered":true,"active_label":"knox","accounts":[{"label":"knox","email":"knox@example.com","token":"sk-ant-oat01-FAKEKNOX","active":true},{"label":"ministry","email":"ministry@example.com","token":"sk-ant-oat01-FAKEMIN","active":true},{"label":"ops","email":"ops@example.com","token":"sk-ant-oat01-FAKEOPS","active":true},{"label":"old","email":"old@example.com","token":"sk-ant-oat01-FAKEOLD","active":false}]}' > "$XDG_CONFIG_HOME/claude-pwt/accounts.json"; chmod 600 "$XDG_CONFIG_HOME/claude-pwt/accounts.json"

PY="python3 -c"
cd "$HERE"
echo "probe-scoped.test.sh"
# 1. pure parser
r=$($PY 'import probe,json
print(probe.parse_scoped_usage(json.dumps({"limits":[{"kind":"weekly_scoped","percent":83,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_all","percent":9},{"kind":"weekly_scoped","percent":True,"scope":{"model":{"display_name":"X"}}}]})),
      probe.parse_scoped_usage(b"garbage"), probe.parse_scoped_usage({"limits":"nope"}), probe.parse_scoped_usage(None))')
[ "$r" = "{'Fable': 83.0} {} {} {}" ] && ok "parse_scoped_usage: weekly_scoped by display_name; bool/garbage/None ⇒ {}" || bad "parse_scoped_usage" "$r"
# 2. sample lookup by email picks the NEWEST; unknown email ⇒ None; malformed file skipped
r=$($PY 'import probe
s=probe._plan_usage_scoped_sample("knox@example.com"); print(s[0], int(s[1]))
print(probe._plan_usage_scoped_sample("nobody@example.com"), probe._plan_usage_scoped_sample(""))')
[ "$r" = "{'Fable': 86.0} $((NOW-60))
None None" ] && ok "sample lookup: newest sample for the email; unknown/empty email ⇒ None" || bad "sample lookup" "$r"
# 3. probe_scoped: no sample + GET off ⇒ None without calling transport; GET on ⇒ 200 parsed, 403/429 ⇒ None
r=$($PY 'import probe,os,json
calls=[]
def t200(u,h,to): calls.append(("200",u,"Bearer sk-ant-oat01-FAKEOPS"==h["Authorization"])); return 200, json.dumps({"limits":[{"kind":"weekly_scoped","percent":75,"scope":{"model":{"display_name":"Fable"}}}]}).encode()
def t403(u,h,to): calls.append(("403",)); return 403, b""
def t429(u,h,to): calls.append(("429",)); return 429, b""
def tnet(u,h,to): raise probe.MeasurementError("network: X")
print(probe.probe_scoped("sk-ant-oat01-FAKEOPS","ops@example.com",transport=t200,now=1000.0), len(calls))
os.environ["PWT_ACCT_SCOPED_PROBE"]="1"
print(probe.probe_scoped("sk-ant-oat01-FAKEOPS","ops@example.com",transport=t200,now=1000.0))
print(probe.probe_scoped("tok","ops@example.com",transport=t403), probe.probe_scoped("tok","ops@example.com",transport=t429), probe.probe_scoped("tok","ops@example.com",transport=tnet), probe.probe_scoped("","ops@example.com",transport=t200))
print(calls[0][1]==probe.SCOPED_URL and calls[0][2], [c[0] for c in calls])')
[ "$r" = "None 0
({'Fable': 75.0}, 1000.0)
None None None None
True ['200', '403', '429']" ] && ok "probe_scoped: GET is opt-in (default no transport call); 200 ⇒ (scoped, now); 403/429/network/empty token ⇒ None" || bad "probe_scoped" "$r"
# 4. resolve_usage attaches scoped from the sample, keeps the cached value when the sample vanishes, never carries a token
r=$($PY 'import probe,registry,json,os
reg=json.load(open(os.path.join(os.environ["XDG_CONFIG_HOME"],"claude-pwt","accounts.json")))
def hdr(u,d,h,to): return 200, {"anthropic-ratelimit-unified-5h-utilization":"0.10","anthropic-ratelimit-unified-7d-utilization":"0.50","anthropic-ratelimit-unified-status":"allowed","anthropic-ratelimit-unified-5h-reset":"1900000000","anthropic-ratelimit-unified-7d-reset":"1900000000"}
gs={g["label"]:g for g in probe.resolve_usage(reg,ttl=0,transport=hdr)}
print(gs["knox"].get("scoped"), gs["ministry"].get("scoped"), gs["ops"].get("scoped"), "old" in gs, any("token" in g for g in gs.values()))
os.remove(os.path.join(os.environ["PLAN_USAGE_CACHE_DIR"],"bbbb.json")); os.remove(os.path.join(os.environ["PLAN_USAGE_CACHE_DIR"],"aaaa.json"))
gs={g["label"]:g for g in probe.resolve_usage(reg,ttl=0,transport=hdr)}
print(gs["knox"].get("scoped"), bool(gs["knox"].get("scoped_at")))
c=json.load(open(probe.resolve_cache_path())); print(c["gauges"]["knox"]["scoped"], "sk-ant" in open(probe.resolve_cache_path()).read())')
[ "$r" = "{'Fable': 86.0} {'Fable': 34.0} None False False
{'Fable': 86.0} True
{'Fable': 86.0} False" ] && ok "resolve_usage: scoped attached per account, retained from cache when the sample is gone, cache token-free" || bad "resolve_usage scoped" "$r"
# 5. status table: FABLE% column after 7d%, '?' when absent, '-' for deactivated, age tag past PWT_ACCT_SCOPED_TTL
sample bbbb knox@example.com $((NOW-60)) 86
export PWT_ACCT_USAGE_TTL=99999   # gauges above are fresh in the cache ⇒ no header probe (no network)
OUT=$(bash ./accounts.sh status 2>&1); rc=$?
echo "$OUT" | grep -q '^PIN  LABEL  *EMAIL  *5h%  *7d%  *FABLE%  *WINDOW' && ok "status header: FABLE% column sits after 7d%" || bad "status header" "$OUT"
echo "$OUT" | grep -E '^\*  *knox  .*  86\.0  +-  ' >/dev/null && ok "status row: knox shows a fresh Fable 86.0 with no age tag" || bad "knox row" "$OUT"
echo "$OUT" | grep -E '^ +ministry  .*  34\.0 ~1d2h  +-  ' >/dev/null && ok "status row: a 26h-old sample is shown tagged ~1d2h" || bad "ministry age tag" "$OUT"
echo "$OUT" | grep -E '^ +ops  .*  \?  +-  ' >/dev/null && ok "status row: no sample ⇒ ?" || bad "ops ? cell" "$OUT"
echo "$OUT" | grep -E '^ +old  .*  -  +-  +-  +-  +-  +deactivated' >/dev/null && ok "status row: deactivated pads the scoped column with -" || bad "deactivated row" "$OUT"
echo "$OUT" | grep -q 'sk-ant' && bad "status leaks a token" || ok "status output carries no token"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || { printf '  - %s\n' "${NOTES[@]}"; exit 1; }
