//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract RfqErrors {
    error RfqControl_PreSolver_BuyTokenMismatch();
    error RfqControl_PreSolver_SellTokenMismatch();
    error RfqControl_PreSolver_BidBelowReserve();
    error RfqControl_PostOpsCall_InsufficientBaseline();
    error RfqControl_BaselineSwap_BaselineCallFail();
    error RfqControl_BaselineSwap_NoBalanceIncrease();
    error RfqControl_BalanceCheckFail();
    error RfqControl_Swap_OnlyAtlas();
    error RfqControl_Swap_MustBeDelegated();
    error RfqControl_Swap_BuyAndSellTokensAreSame();
    error RfqControl_Swap_UserOpValueTooLow();
    error RfqControl_Swap_BaselineCallValueTooLow();
    error RfqControl_SimulationResult(uint256 amountOut);
    error RfqControl_Swap_SimulationFailed();
}
