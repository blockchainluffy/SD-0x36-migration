// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Step2_VerifySpace } from "./Step2_VerifySpace.s.sol";

/// @title Step 3 — update the space controller to the Security Council
/// @notice A separate step on purpose. On mainnet the space is created with the dev
///         wallet as controller, its parameters are verified (Step 2) and reviewed,
///         and only then is the controller moved to the Security Council multisig —
///         a distinct transaction, signed by the dev wallet, not a DAO vote.
///
///         `Space.transferOwnership` is OpenZeppelin `onlyOwner` and single-step, and
///         touches only the `Space` contract: no Safe transaction, no module, no vote.
///         That is why it can — and here does — run while the strategy is still not a
///         Safe module. See `_handOverController` in SimBase for the assertions.
///
/// Run:  forge script script/Step3_UpdateController.s.sol -vv
contract Step3_UpdateController is Step2_VerifySpace {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _report("Step 3");
        _writeState("3");
    }

    function _step3() internal {
        _handOverController();
    }
}
