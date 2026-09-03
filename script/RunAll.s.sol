// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Step6_RemoveAzorius } from "./Step6_RemoveAzorius.s.sol";

/// @title RunAll — all six migration steps in one narrated run
/// @dev    Identical to running Step 6 (each step replays the ones before it);
///         this is just the obvious entry point.
///
/// Run:  forge script script/RunAll.s.sol -vv
contract RunAll is Step6_RemoveAzorius { }
