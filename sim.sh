#!/usr/bin/env bash
#
# sim.sh — driver for the Shutter DAO 0x36 governance migration simulation.
#
# Simulations (fork only, nothing is signed or broadcast):
#
#   ./sim.sh             run all six steps
#   ./sim.sh 4           run step 4 (steps 1-3 are replayed first)
#   ./sim.sh all -vvv    pass extra flags straight through to forge
#   ./sim.sh test        run the same thing as a forge test suite
#   ./sim.sh probe       what works before the module is enabled?
#   ./sim.sh azorius     prove Azorius can do nothing after removal
#   ./sim.sh exec-matrix ETH/batch/delegatecall/failure/perm-exec + gov admin tests
#   ./sim.sh veto-window when can the Security Council still cancel a proposal?
#   ./sim.sh quorum      which vote choices count towards quorum?
#
# Transaction builders (write ready-to-use files into ./sim):
#
#   ./sim.sh enable-tx --strategy 0xSTRATEGY        Vote 1: enableModule(strategy)
#                                                   (Vote 1 is already done on mainnet,
#                                                    so this now stops on purpose)
#   ./sim.sh vote2-tx  --strategy 0xSTRATEGY        Vote 2: swapOwner + disableModule
#   ./sim.sh cancel-tx --space 0xSPACE --proposal 5 Security Council veto: cancel(id)
#
# Set the dev wallet that signs "Create" in the UI (salts the space + strategy
# addresses and is the space's initial controller):
#
#   ./sim.sh 1 --deployer 0xYOURDEVWALLET
#   SPACE_DEPLOYER=0xYOURDEVWALLET ./sim.sh
#
# Attach to a space that already exists on chain, so any step can be run on its
# own against the real deployment (Step 1 skips creation):
#
#   ./sim.sh 2 --space 0xSPACE --strategy 0xSTRATEGY
#   SNAPSHOT_X_SPACE=0x... SNAPSHOT_X_STRATEGY=0x... ./sim.sh 4
#
# Find the strategy address with:  ./snapx-strategy.sh from-tx <SPACE_CREATE_TX>
#
# Everything happens inside forge's in-memory mainnet fork. Nothing is signed,
# nothing is broadcast.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
[ -f .env ] && set -a && . ./.env && set +a
export MAINNET_RPC_URL="${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"

STEP="${1:-all}"
shift || true

# --space / --strategy are sugar for the SNAPSHOT_X_* env vars.
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --space)      export SNAPSHOT_X_SPACE="$2"; shift 2;;
    --strategy)   export SNAPSHOT_X_STRATEGY="$2"; shift 2;;
    --deployer)   export SPACE_DEPLOYER="$2"; shift 2;;
    --controller) export SPACE_CONTROLLER="$2"; shift 2;;
    --proposal)   export PROPOSAL_ID="$2"; shift 2;;
    *)          ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "$STEP" in
  1) SCRIPT=script/Step1_CreateSpace.s.sol ;;
  2) SCRIPT=script/Step2_VerifySpace.s.sol ;;
  3) SCRIPT=script/Step3_UpdateController.s.sol ;;
  4) SCRIPT=script/Step4_EnableModule.s.sol ;;
  5) SCRIPT=script/Step5_VerifyVoting.s.sol ;;
  6) SCRIPT=script/Step6_RemoveAzorius.s.sol ;;
  all) SCRIPT=script/RunAll.s.sol ;;
  probe) SCRIPT=script/ProbeNotYetEnabled.s.sol ;;
  azorius) SCRIPT=script/AzoriusNeutralized.s.sol ;;
  exec-matrix) SCRIPT=script/ExecMatrix.s.sol:ExecMatrix ;;
  veto-window) SCRIPT=script/VetoWindow.s.sol ;;
  quorum) SCRIPT=script/QuorumRules.s.sol ;;
  enable-tx) SCRIPT=script/BuildEnableModuleTx.s.sol ;;
  vote2-tx) SCRIPT=script/BuildVote2Tx.s.sol ;;
  cancel-tx)
    SCRIPT=script/BuildCancelProposalTx.s.sol
    : "${PROPOSAL_ID:?cancel-tx needs a proposal id: ./sim.sh cancel-tx --space 0x... --proposal 5}" ;;
  test) exec forge test "$@" ;;
  -h|--help|help)
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *)
    echo "unknown step: $STEP" >&2
    echo "expected one of: 1-6, all, probe, azorius, exec-matrix, veto-window, quorum," >&2
    echo "                 enable-tx, vote2-tx, cancel-tx, test        (./sim.sh help)" >&2
    exit 1 ;;
esac

mkdir -p sim
echo "RPC:        $MAINNET_RPC_URL"
echo "fork block: ${FORK_BLOCK:-latest}"
echo "script:     $SCRIPT"
if [ -n "${SNAPSHOT_X_SPACE:-}" ]; then
  echo "mode:       attached"
  echo "  space:    $SNAPSHOT_X_SPACE"
  echo "  strategy: ${SNAPSHOT_X_STRATEGY:-<missing - required>}"
else
  echo "mode:       fresh (Step 1 creates the space)"
  echo "  deployer: ${SPACE_DEPLOYER:-<default sim dev wallet>}"
fi
echo

forge script "$SCRIPT" -vv "$@"
