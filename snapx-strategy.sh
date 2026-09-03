#!/usr/bin/env bash
#
# snapx-strategy.sh — locate & verify a Snapshot X "Safe module (Zodiac)" execution
# strategy for the Shutter DAO 0x36 migration (Decent -> Snapshot X).
#
# The strategy contract address does NOT exist until the Snapshot X space is created.
# It is deployed by Snapshot X's ProxyFactory via CREATE2, so:
#   - it is emitted in a `ProxyDeployed(address implementation, address proxy)` event, and
#   - it is deterministic in (factory, implementation, msg.sender/deployer, saltNonce).
#
# This script lets you:
#   from-tx  : pull the deployed strategy address out of the create transaction and verify it
#   check    : verify a known strategy address against the expected migration parameters
#   predict  : pre-compute the CREATE2 address from (implementation, deployer, saltNonce)
#
# It checks ONLY read-only state. It signs nothing and sends nothing.
#
# Requirements: foundry (cast), python3.
#
# ---------------------------------------------------------------------------
set -euo pipefail

# ===== Expected parameters (from "SD 0x36_Snapshot X" migration doc) =========
# Edit here if the doc changes.
SAFE="0x36bD3044ab68f600f6d3e081056F34f2a58432c4"          # Treasury / target (avatar) / controller
EXPECTED_TARGET="$SAFE"                                     # AvatarExecutionStrategy.target()  -> the Safe
EXPECTED_OWNER="$SAFE"                                      # owner()  -> the "Controller address" in the doc
EXPECTED_QUORUM="30000000000000000570425344"                # quorum() -> 30,000,000 SHU as snapshot.box stores it (float64 of 30M*1e18)
EXPECTED_TYPE="SimpleQuorumAvatar"                         # getStrategyType() for AvatarExecutionStrategy
DECENT_MODULE="0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e" # current Decent (Azorius) module, for reference

# ===== Defaults =============================================================
DEFAULT_RPC="${RPC_URL:-https://ethereum-rpc.publicnode.com}"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# ===== Helpers ==============================================================
c_red() { printf '\033[31m%s\033[0m' "$1"; }
c_grn() { printf '\033[32m%s\033[0m' "$1"; }
c_dim() { printf '\033[2m%s\033[0m' "$1"; }

PASS=0; FAIL=0
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
strip() { awk '{print $1}' | tr -d '"'; }   # cast prints e.g. `30000000000000000000 [3e19]` or `"str"`

# eq <label> <actual> <expected>
eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$(lc "$actual")" = "$(lc "$expected")" ]; then
    printf '  [%s] %-22s %s\n' "$(c_grn PASS)" "$label" "$actual"; PASS=$((PASS+1))
  else
    printf '  [%s] %-22s %s\n' "$(c_red FAIL)" "$label" "$actual"
    printf '        %s %s\n' "$(c_dim 'expected:')" "$expected"; FAIL=$((FAIL+1))
  fi
}

usage() {
  cat <<EOF
snapx-strategy.sh — verify the Snapshot X execution strategy for Shutter DAO 0x36

USAGE
  ./snapx-strategy.sh from-tx  <DEPLOY_TX_HASH> [--space <SPACE_ADDR>] [--rpc <URL>]
  ./snapx-strategy.sh check    <STRATEGY_ADDR>  [--space <SPACE_ADDR>] [--rpc <URL>]
  ./snapx-strategy.sh predict  <IMPLEMENTATION> <DEPLOYER> <SALT_NONCE> <FACTORY> [--rpc <URL>]

NOTES
  --space  Optionally also assert the strategy whitelists your Snapshot X space
           (isSpaceEnabled(space) == 1). The space address is itself only known
           after creation; read it from the space settings or the deploy tx.
  --rpc    Ethereum mainnet RPC. Defaults to \$RPC_URL or a public node.

EXAMPLES
  ./snapx-strategy.sh from-tx 0xabc...def --space 0xSPACE
  ./snapx-strategy.sh check   0xSTRATEGY  --space 0xSPACE
  ./snapx-strategy.sh predict 0xIMPL 0xDEPLOYER 1717171717 0xFACTORY
EOF
}

# ===== Core: verify a strategy address ======================================
check_strategy() {
  local S="$1" RPC="$2" SPACE="${3:-}"
  echo "Strategy: $S"
  echo "RPC:      $RPC"
  echo

  local code
  code=$(cast code "$S" --rpc-url "$RPC")
  if [ "$code" = "0x" ] || [ -z "$code" ]; then
    echo "  $(c_red 'ERROR') no contract code at $S — not deployed on this network."; exit 1
  fi

  local TYPE TARGET OWNER QUORUM
  TYPE=$(cast call "$S" "getStrategyType()(string)" --rpc-url "$RPC" 2>/dev/null | strip || true)
  TARGET=$(cast call "$S" "target()(address)" --rpc-url "$RPC" 2>/dev/null | strip || true)
  OWNER=$(cast call "$S" "owner()(address)" --rpc-url "$RPC" 2>/dev/null | strip || true)
  QUORUM=$(cast call "$S" "quorum()(uint256)" --rpc-url "$RPC" 2>/dev/null | strip || true)

  echo "Verifying against migration-doc parameters:"
  eq "strategy type"   "${TYPE:-<none>}"   "$EXPECTED_TYPE"
  eq "target (avatar)" "${TARGET:-<none>}" "$EXPECTED_TARGET"
  eq "owner (controller)" "${OWNER:-<none>}" "$EXPECTED_OWNER"
  eq "quorum"          "${QUORUM:-<none>}" "$EXPECTED_QUORUM"

  if [ -n "$SPACE" ]; then
    local EN
    EN=$(cast call "$S" "isSpaceEnabled(address)(uint256)" "$SPACE" --rpc-url "$RPC" 2>/dev/null | strip || true)
    eq "space whitelisted"  "${EN:-<none>}" "1"
    echo "        (space checked: $SPACE)"
  else
    echo "  $(c_dim '[skip] space whitelist — pass --space <addr> to assert isSpaceEnabled == 1')"
  fi

  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "$(c_grn "ALL $PASS CHECKS PASSED.") Safe to use this address in enableModule()."
    echo
    echo "Next: TX 1 calldata for the Safe ($SAFE):"
    echo "  enableModule($S)"
    cast calldata "enableModule(address)" "$S"
  else
    echo "$(c_red "$FAIL CHECK(S) FAILED") ($PASS passed). Do NOT enable this module until resolved."
    exit 1
  fi
}

# ===== from-tx: extract strategy from the deploy tx receipt ==================
cmd_from_tx() {
  local TX="$1" RPC="$2" SPACE="${3:-}"
  [ -n "$TX" ] || { usage; exit 1; }
  echo "Reading ProxyDeployed events from $TX ..."
  local TOPIC
  TOPIC=$(cast keccak "ProxyDeployed(address,address)")

  # Pull every proxy address emitted in this tx (a space create emits several:
  # the space proxy + one proxy per execution strategy). Both event args are
  # non-indexed, so the proxy is the 2nd 32-byte word of each log's data.
  local PROXIES
  PROXIES=$(cast receipt "$TX" --rpc-url "$RPC" --json \
    | python3 -c "
import sys,json
topic='$TOPIC'.lower()
r=json.load(sys.stdin)
for lg in r.get('logs',[]):
    t=[x.lower() for x in lg.get('topics',[])]
    if t and t[0]==topic:
        d=lg['data'][2:]
        proxy='0x'+d[64:128][24:]   # 2nd word, low 20 bytes
        print(proxy)
")
  if [ -z "$PROXIES" ]; then
    echo "  $(c_red 'ERROR') no ProxyDeployed events in this tx. Wrong tx hash or wrong network?"; exit 1
  fi

  echo "Candidate proxies deployed in this tx:"
  printf '  %s\n' $PROXIES
  echo

  # Identify the AvatarExecutionStrategy among the candidates.
  local FOUND=""
  for P in $PROXIES; do
    local t
    t=$(cast call "$P" "getStrategyType()(string)" --rpc-url "$RPC" 2>/dev/null | strip || true)
    if [ "$t" = "$EXPECTED_TYPE" ]; then FOUND="$P"; break; fi
  done

  if [ -z "$FOUND" ]; then
    echo "  $(c_red 'ERROR') none of the deployed proxies is a $EXPECTED_TYPE strategy."
    echo "  (Is this the correct create tx? Was a different execution strategy chosen?)"; exit 1
  fi
  echo "Identified execution strategy: $(c_grn "$FOUND")"
  echo
  check_strategy "$FOUND" "$RPC" "$SPACE"
}

# ===== predict: CREATE2 address before deploying ============================
# salt = keccak256(abi.encodePacked(deployer, saltNonce))
# addr = keccak256(0xff ++ factory ++ salt ++ keccak256(ERC1967Proxy.creationCode ++ abi.encode(impl,"")))
# The creationCode hash is chain/version specific; we ask the factory itself
# via predictProxyAddress(impl, salt) so we never hardcode bytecode.
cmd_predict() {
  local IMPL="$1" DEPLOYER="$2" NONCE="$3" FACTORY="$4" RPC="$5"
  [ -n "$IMPL" ] && [ -n "$DEPLOYER" ] && [ -n "$NONCE" ] && [ -n "$FACTORY" ] || { usage; exit 1; }
  local SALT PRED
  SALT=$(cast keccak "$(cast abi-encode --packed "f(address,uint256)" "$DEPLOYER" "$NONCE")")
  echo "implementation : $IMPL"
  echo "deployer       : $DEPLOYER"
  echo "saltNonce      : $NONCE"
  echo "factory        : $FACTORY"
  echo "salt           : $SALT"
  PRED=$(cast call "$FACTORY" "predictProxyAddress(address,bytes32)(address)" "$IMPL" "$SALT" --rpc-url "$RPC" | strip)
  echo
  echo "predicted strategy address: $(c_grn "$PRED")"
  echo "$(c_dim 'NOTE: changes if the deployer wallet, saltNonce, implementation, factory, or chain change.')"
}

# ===== Arg parsing ==========================================================
[ $# -ge 1 ] || { usage; exit 1; }
SUB="$1"; shift || true
RPC="$DEFAULT_RPC"; SPACE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc)   RPC="$2"; shift 2;;
    --space) SPACE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) POS+=("$1"); shift;;
  esac
done

case "$SUB" in
  from-tx) cmd_from_tx "${POS[0]:-}" "$RPC" "$SPACE";;
  check)   check_strategy "${POS[0]:-}" "$RPC" "$SPACE";;
  predict) cmd_predict "${POS[0]:-}" "${POS[1]:-}" "${POS[2]:-}" "${POS[3]:-}" "$RPC";;
  -h|--help|help) usage;;
  *) echo "unknown subcommand: $SUB"; echo; usage; exit 1;;
esac
