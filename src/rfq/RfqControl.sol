//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "@atlas/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/types/ConfigTypes.sol";
import "@atlas/types/UserOperation.sol";
import "@atlas/types/SolverOperation.sol";

import { SwapIntent, BaselineCall } from "src/rfq/RfqTypes.sol";
import { RfqErrors } from "src/rfq/RfqErrors.sol";

contract RfqControl is DAppControl, RfqErrors {
    uint256 public constant MAX_SOLVER_GAS = 500_000;

    address internal constant NATIVE_TOKEN = address(0);
    address public immutable feeRecipient; // Address to receive the fees
    uint256 public immutable fee; // Fee in basis points (e.g., 50 = 0.5%)

    address private immutable SELF;

    constructor(
        address _atlas,
        address _feeRecipient,
        uint256 _fee
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: false,
                trackPreOpsReturnData: false,
                trackUserReturnData: true,
                delegateUser: true,
                requirePreSolver: true,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: true,
                reuseUserOp: true,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: false,
                forwardReturnData: true,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    {
        SELF = address(this);
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_fee <= 10_000, "Fee too high"); // Maximum is 100% (10000 basis points)
        feeRecipient = _feeRecipient;
        fee = _fee;
    }

    // ---------------------------------------------------- //
    //                    UserOp Function                   //
    // ---------------------------------------------------- //

    /*
    * @notice This is the user operation target function
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It checks that the user has approved Atlas to spend the tokens they are selling
    * @param swapIntent The SwapIntent struct
    * @param baselineCall The BaselineCall struct
    * @return The SwapIntent and the BaselineCall structs that were passed in
    */
    function swap(
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall
    )
        external
        payable
        returns (SwapIntent memory, BaselineCall memory)
    {
        if (msg.sender != ATLAS) {
            revert RfqErrors.RfqControl_Swap_OnlyAtlas();
        }
        if (address(this) == CONTROL) {
            revert RfqErrors.RfqControl_Swap_MustBeDelegated();
        }
        if (swapIntent.tokenUserSells == swapIntent.tokenUserBuys) {
            revert RfqErrors.RfqControl_Swap_BuyAndSellTokensAreSame();
        }

        // Transfer sell token if it isn't native token and validate value deposit if it is
        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            _transferUserERC20(swapIntent.tokenUserSells, address(this), swapIntent.amountUserSells);
        } else {
            // UserOp.value already passed to this contract - ensure that userOp.value matches sell amount
            if (msg.value < swapIntent.amountUserSells) revert RfqErrors.RfqControl_Swap_UserOpValueTooLow();
            if (baselineCall.value < swapIntent.amountUserSells) {
                revert RfqErrors.RfqControl_Swap_BaselineCallValueTooLow();
            }
        }

        // For Simulation, approve the control contract to spend the sell token
        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            SafeTransferLib.safeApprove(swapIntent.tokenUserSells, CONTROL, swapIntent.amountUserSells);
        }

        // Build the payload to invoke simulateBaselineSwap
        bytes memory payload = abi.encodeWithSelector(
            this.simulateBaselineSwap.selector,
            swapIntent,
            baselineCall
        );

        // Call it (it always reverts with your result)
        (bool success, bytes memory revertData) =
            address(CONTROL).call{ value: msg.value }(payload);

        // Ensure it indeed reverted
        if (success) revert RfqErrors.RfqControl_BaselineSwap_SimulationDidNotRevert();

        // RevertData = 4-byte selector + abi.encode(uint256)
        //    so skip the selector to get at the uint256
        if (revertData.length < 4 + 32) revert RfqErrors.RfqControl_BaselineSwap_SimulationFailed();
        
        // Extract the uint256 out of the revertData
        uint256 amountOut;
        assembly {
            // revertData is a `bytes` in memory:
            // 0x00: length
            // 0x20: data[0..31] → [ selector (4B) | first 28B of your uint256 ]
            // so we want the word at revertData + 32 + 4 = revertData + 36
            amountOut := mload(add(revertData, 36))
        }

        // Verify that the amount out is greater than or equal to the minAmountUserBuys
        if (amountOut < swapIntent.minAmountUserBuys) {
            revert RfqErrors.RfqControl_BaselineSwap_AmountOutBelowMin();
        }

        return (swapIntent, baselineCall);
    }

    // ---------------------------------------------------- //
    //                  Atlas Hook Overrides                //
    // ---------------------------------------------------- //

    /*
    * @notice This function is called before a solver operation executes
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers the tokens that the user is selling to the solver
    * @param solverOp The SolverOperation that is about to execute
    * @param returnData The return data from the swap function
    */
    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        (SwapIntent memory _swapIntent,) = abi.decode(returnData, (SwapIntent, BaselineCall));

        // Make sure the token is correct
        if (solverOp.bidToken != _swapIntent.tokenUserBuys) {
            revert RfqErrors.RfqControl_PreSolver_BuyTokenMismatch();
        }
        if (solverOp.bidToken == _swapIntent.tokenUserSells) {
            revert RfqErrors.RfqControl_PreSolver_SellTokenMismatch();
        }

        // NOTE: This module is unlike the generalized swap intent module - here, the solverOp.bidAmount includes
        // the min amount that the user expects.
        // We revert early if the baseline swap returned more than the solver's bid.
        if (solverOp.bidAmount < _swapIntent.minAmountUserBuys) {
            revert RfqErrors.RfqControl_PreSolver_BidBelowReserve();
        }

        // Optimistically transfer the user's sell tokens to the solver.
        if (_swapIntent.tokenUserSells == NATIVE_TOKEN) {
            SafeTransferLib.safeTransferETH(solverOp.solver, _swapIntent.amountUserSells);
        } else {
            SafeTransferLib.safeTransfer(_swapIntent.tokenUserSells, solverOp.solver, _swapIntent.amountUserSells);
        }
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers all the available bid tokens on the contract (instead of only the bid amount, to avoid leaving
    any dust on the contract)
    * @param returnData The return data from the swap function
    */
    function _allocateValueCall(address, uint256, bytes calldata returnData) internal override {
        (SwapIntent memory _swapIntent,) = abi.decode(returnData, (SwapIntent, BaselineCall));
        _sendTokensToUser(_swapIntent, fee);
    }

    /*
    * @notice This function after all solver operations have executed
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It does the baseline call and transfers the tokens to the user if no solver beat the baseline
    * @param solved Whether a solver has beat the baseline
    * @param returnData The return data from the swap function
    */
    function _postOpsCall(bool solved, bytes calldata returnData) internal override {
        // If a solver beat the baseline and the amountOutMin, return early
        if (solved) {
            return;
        }

        (SwapIntent memory _swapIntent, BaselineCall memory _baselineCall) =
            abi.decode(returnData, (SwapIntent, BaselineCall));

        // Do the baseline call
        uint256 _buyTokensReceived = _baselineSwap(_swapIntent, _baselineCall);

        // console.log(_buyTokensReceived);

        // Verify that it exceeds the minAmountOut
        if (_buyTokensReceived < _swapIntent.minAmountUserBuys) {
            revert RfqErrors.RfqControl_PostOpsCall_InsufficientBaseline();
        }

        // Undo the token approval, if not native token.
        if (_swapIntent.tokenUserSells != NATIVE_TOKEN) {
            SafeTransferLib.safeApprove(_swapIntent.tokenUserSells, _baselineCall.to, 0);
        }

        // Transfer tokens to user
        _sendTokensToUser(_swapIntent, 0);
    }

    // ---------------------------------------------------- //
    //                   Custom Functions                   //
    // ---------------------------------------------------- //

    /*
    * @notice This function transfers the tokens to the user
    * @param swapIntent The SwapIntent struct
    */
    function _sendTokensToUser(SwapIntent memory swapIntent, uint256 feePerc) internal {
        uint256 amountToSend = 0;
        uint256 feeAmount = 0;
        // Transfer the buy token
        if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
            uint256 totalBalance = address(this).balance;
            feeAmount = (totalBalance * feePerc) / 10_000;
            amountToSend = totalBalance - feeAmount;

            // Transfer the fee to the feeRecipient
            if (feeAmount > 0) {
                SafeTransferLib.safeTransferETH(feeRecipient, feeAmount);
            }

            // Transfer the remaining amount to the user
            SafeTransferLib.safeTransferETH(_user(), amountToSend);
        } else {
            uint256 totalBalance = _getBalance(swapIntent.tokenUserBuys, address(this));
            feeAmount = (totalBalance * feePerc) / 10_000;
            amountToSend = totalBalance - feeAmount;

            // Transfer the fee to the feeRecipient
            if (feeAmount > 0) {
                SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, feeRecipient, feeAmount);
            }

            // Transfer the remaining amount to the user
            SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, _user(), amountToSend);
        }

        // Transfer any surplus sell token
        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            SafeTransferLib.safeTransferETH(_user(), address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(
                swapIntent.tokenUserSells, _user(), _getBalance(swapIntent.tokenUserSells, address(this))
            );
        }
    }

    /*
    * @notice This function performs the baseline call
    * @param swapIntent The SwapIntent struct
    * @param baselineCall The BaselineCall struct
    * @return The amount of tokens received
    */
    function _baselineSwap(
        SwapIntent memory swapIntent,
        BaselineCall memory baselineCall
    )
        internal
        returns (uint256 received)
    {
        // Track the balance (count any previously-forwarded tokens)
        uint256 _startingBalance = _getBalance(swapIntent.tokenUserBuys, address(this));

        // CASE not native token
        // NOTE: if native token, pass as value
        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            // Approve the router (NOTE that this approval happens either inside the try/catch and is reverted
            // or in the postOps hook where we cancel it afterwards.
            SafeTransferLib.safeApprove(swapIntent.tokenUserSells, baselineCall.to, swapIntent.amountUserSells);
        }

        // Perform the Baseline Call
        (bool _success,) = baselineCall.to.call{ value: baselineCall.value }(baselineCall.data);

        // dont pass custom errors
        if (!_success) revert RfqErrors.RfqControl_BaselineSwap_BaselineCallFail();

        // Track the balance delta
        uint256 _endingBalance = _getBalance(swapIntent.tokenUserBuys, address(this));

        // dont pass custom errors
        if (_endingBalance <= _startingBalance) revert RfqErrors.RfqControl_BaselineSwap_NoBalanceIncrease();

        return _endingBalance - _startingBalance;
    }

    /*
    * @notice This function gets the balance of an ERC20 token
    * @param token The address of the token
    * @return The balance of the token
    */
    function _getBalance(address token, address user) internal view returns (uint256 balance) {
        if (token == NATIVE_TOKEN) {
            balance = user.balance;
        } else {
            (bool _success, bytes memory _data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, user));
            if (!_success) revert RfqControl_BalanceCheckFail();
            balance = abi.decode(_data, (uint256));
        }
    }

    /*
    * @notice This function simulates the baseline swap without executing it
    * @param swapIntent The SwapIntent struct
    * @param baselineCall The BaselineCall struct
    * @return The simulated amount of tokens that would be received
    */
    function simulateBaselineSwap(
        SwapIntent memory swapIntent,
        BaselineCall memory baselineCall
    ) external payable returns (uint256) {
        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            SafeTransferLib.safeTransferFrom(swapIntent.tokenUserSells, msg.sender, address(this), swapIntent.amountUserSells);
        }
        
        // Track the current balance
        uint256 _startingBalance = _getBalance(swapIntent.tokenUserSells, msg.sender);

        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            // Approve the router (NOTE that this approval happens either inside the try/catch and is reverted
            // or in the postOps hook where we cancel it afterwards.
            SafeTransferLib.safeApprove(swapIntent.tokenUserSells, baselineCall.to, swapIntent.amountUserSells);
        }

        // Make the call
        (bool success,) = baselineCall.to.call{value: baselineCall.value}(baselineCall.data);
        if (!success) revert RfqErrors.RfqControl_BaselineSwap_BaselineCallFail();

        // Get the ending balance
        uint256 _endingBalance = _getBalance(swapIntent.tokenUserBuys, msg.sender);
        
        if (_endingBalance <= _startingBalance) revert RfqErrors.RfqControl_BaselineSwap_NoBalanceIncrease();

        // Calculate amount out
        uint256 amountOut = _endingBalance - _startingBalance;
        
        // Always revert with the amount out
        revert RfqControl_SimulationResult(amountOut);
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        (SwapIntent memory _swapIntent,) = abi.decode(userOp.data[4:], (SwapIntent, BaselineCall));
        bidToken = _swapIntent.tokenUserBuys;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getSolverGasLimit() public pure override returns (uint32) {
        return uint32(MAX_SOLVER_GAS);
    }
}
