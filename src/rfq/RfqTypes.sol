//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";

// External representation of the swap intent
struct SwapIntent {
    address tokenUserBuys;
    uint256 minAmountUserBuys;
    address tokenUserSells;
    uint256 amountUserSells;
}

struct BaselineCall {
    address to; // Address to send the swap if there are no solvers / to get the baseline
    bytes data; // Calldata for the baseline swap
    uint256 value; // msg.value of the swap (native gas token)
}

struct Reputation {
    uint128 successCost;
    uint128 failureCost;
}

struct AtlasOps {
    UserOperation userOp;
    SolverOperation[] solverOps;
    DAppOperation dappOp;
}
