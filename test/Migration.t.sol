// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

import { Step1_CreateSpace } from "../script/Step1_CreateSpace.s.sol";
import { Step2_VerifySpace } from "../script/Step2_VerifySpace.s.sol";
import { Step3_UpdateController } from "../script/Step3_UpdateController.s.sol";
import { Step4_EnableModule } from "../script/Step4_EnableModule.s.sol";
import { Step5_VerifyVoting } from "../script/Step5_VerifyVoting.s.sol";
import { Step6_RemoveAzorius } from "../script/Step6_RemoveAzorius.s.sol";
import { AzoriusNeutralized } from "../script/AzoriusNeutralized.s.sol";

/// @notice CI form of the simulation. Each step script reverts if any of its
///         checks fail, so a green test run means every assertion held.
/// @dev    Needs MAINNET_RPC_URL. Pin FORK_BLOCK for fast, cached reruns.
contract MigrationTest is Test {
    function test_Step1_CreateSpace() public {
        new Step1_CreateSpace().run();
    }

    function test_Step2_VerifySpace() public {
        new Step2_VerifySpace().run();
    }

    function test_Step3_UpdateController() public {
        new Step3_UpdateController().run();
    }

    function test_Step4_EnableModule() public {
        new Step4_EnableModule().run();
    }

    function test_Step5_VerifyVoting() public {
        new Step5_VerifyVoting().run();
    }

    function test_Step6_RemoveAzorius() public {
        new Step6_RemoveAzorius().run();
    }

    function test_AzoriusNeutralized() public {
        new AzoriusNeutralized().run();
    }
}
