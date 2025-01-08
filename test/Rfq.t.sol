// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { BaseTest } from "@atlas-test/base/BaseTest.t.sol";

import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";

import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";

import { RfqControl } from "src/rfq/RfqControl.sol";
import { SwapIntent, BaselineCall, AtlasOps } from "src/rfq/RfqTypes.sol";

import { IUniswapV2Router02 } from "@atlas-test/base/interfaces/IUniswapV2Router.sol";

import "forge-std/Test.sol";

contract RfqTest is BaseTest {
    address internal constant NATIVE_TOKEN = address(0);

    uint256 internal constant AUCTIONEER_PK = 11_113;
    address internal immutable AUCTIONEER = vm.addr(AUCTIONEER_PK);

    //feeRecipient
    uint256 internal constant FEE_RECIPIENT_PK = 11_114;
    address internal immutable FEE_RECIPIENT = vm.addr(FEE_RECIPIENT_PK);
    uint256 internal constant FEE = 25; //25 basis point fee

    IUniswapV2Router02 routerV2 = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    uint256 goodSolverBidETH = 1.2 ether; // more than baseline swap amountOut if tokenOut is WETH/ETH
    uint256 goodSolverBidDAI = 3150e18; // more than baseline swap amountOut if tokenOut is DAI

    // 3200 DAI for 1 WETH (no native tokens)
    SwapIntent defaultSwapIntent = SwapIntent({
        tokenUserBuys: WETH_ADDRESS,
        minAmountUserBuys: 1e18,
        tokenUserSells: DAI_ADDRESS,
        amountUserSells: 3200e18
    });

    // 1 ETH for 3100 DAI
    SwapIntent defaultSwapIntent2 = SwapIntent({
        tokenUserBuys: DAI_ADDRESS,
        minAmountUserBuys: 3050e18,
        tokenUserSells: address(0),
        amountUserSells: 1e18
    });

    // 3100 DAI for ETH
    SwapIntent defaultSwapIntent3 = SwapIntent({
        tokenUserBuys: address(0),
        minAmountUserBuys: 1 ether,
        tokenUserSells: DAI_ADDRESS,
        amountUserSells: 3200e18
    });

    RfqControl rfq;
    address executionEnvironment;

    TxBuilder public txBuilder;

    Sig sig;

    function setUp() public virtual override {
        BaseTest.setUp();

        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        //ETH was just under $3100 at this block
        vm.rollFork(20_385_779);

        //Dapp control
        rfq = new RfqControl(address(atlas), address(FEE_RECIPIENT), FEE);
        atlasVerification.initializeGovernance(address(rfq));

        // Auctioneer is a signatory for the RFQ dApp
        atlasVerification.addSignatory(address(rfq), AUCTIONEER);

        //txBuilder helper
        txBuilder =
            new TxBuilder({ _control: address(rfq), _atlas: address(atlas), _verification: address(atlasVerification) });
    }

    function testAtlasRFQ_wethForDai() public {
        //Choose the swap intent for the test
        SwapIntent memory swapIntent = defaultSwapIntent;
        (
            address solverContract,
            SolverOperation[] memory solverOps,
            UserOperation memory userOp,
            DAppOperation memory dAppOp
        ) = _setUpOperations(swapIntent, true, userEOA, 0);

        printBeforeBalances(swapIntent, userEOA, solverContract);

        vm.startPrank(userEOA);
        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");
        
        IERC20(swapIntent.tokenUserSells).approve(address(atlas), swapIntent.amountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: governanceEOA });
        vm.stopPrank();

        printAfterBalances(swapIntent, userEOA, solverContract);
    }

    function testAtlasRFQ_nativeEthForDai() public {
        //Choose the swap intent for the test
        SwapIntent memory swapIntent = defaultSwapIntent2;
        (
            address solverContract,
            SolverOperation[] memory solverOps,
            UserOperation memory userOp,
            DAppOperation memory dAppOp
        ) = _setUpOperations(swapIntent, true, userEOA, swapIntent.amountUserSells);

        printBeforeBalances(swapIntent, userEOA, solverContract);

        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        atlas.metacall{ value: userOp.value }({
            userOp: userOp,
            solverOps: solverOps,
            dAppOp: dAppOp,
            gasRefundBeneficiary: governanceEOA
        });
        vm.stopPrank();

        printAfterBalances(swapIntent, userEOA, solverContract);
    }

    function testAtlasRFQ_nativeEthForDai_baselineSucceeds() public {
        //Choose the swap intent for the test
        SwapIntent memory swapIntent = defaultSwapIntent2;
        (
            address solverContract,
            SolverOperation[] memory solverOps,
            UserOperation memory userOp,
            DAppOperation memory dAppOp
        ) = _setUpOperations(swapIntent, false, userEOA, swapIntent.amountUserSells);

        printBeforeBalances(swapIntent, userEOA, solverContract);

        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        atlas.metacall{ value: userOp.value }({
            userOp: userOp,
            solverOps: solverOps,
            dAppOp: dAppOp,
            gasRefundBeneficiary: governanceEOA
        });
        vm.stopPrank();

        printAfterBalances(swapIntent, userEOA, solverContract);
    }

    function testAtlasRFQ_wethForDai_baselineSucceeds() public {
        //Choose the swap intent for the test
        SwapIntent memory swapIntent = defaultSwapIntent;
        (
            address solverContract,
            SolverOperation[] memory solverOps,
            UserOperation memory userOp,
            DAppOperation memory dAppOp
        ) = _setUpOperations(swapIntent, false, userEOA, 0);

        printBeforeBalances(swapIntent, userEOA, solverContract);

        vm.startPrank(userEOA);
        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");

        IERC20(swapIntent.tokenUserSells).approve(address(atlas), swapIntent.amountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: governanceEOA });
        vm.stopPrank();

        printAfterBalances(swapIntent, userEOA, solverContract);
    }

    // ---------------------------------------------------- //
    //                        Helpers                       //
    // ---------------------------------------------------- //

    // NOTE: This MUST be called at the start of each end-to-end test, to set up args
    function _setUpUser(
        SwapIntent memory swapIntent,
        address from,
        uint256 msgValue
    )
        internal
        returns (UserOperation memory userOp)
    {
        //execution environment
        executionEnvironment = atlas.createExecutionEnvironment(from, address(rfq));
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            deal(swapIntent.tokenUserSells, from, swapIntent.amountUserSells);
        } else {
            deal(from, swapIntent.amountUserSells);
        }

        // Builds the metaTx and to parts of userOp, signature still to be set
        userOp = txBuilder.buildUserOperation({
            from: from,
            to: address(rfq),
            maxFeePerGas: tx.gasprice + 1,
            value: msgValue,
            deadline: block.number + 2,
            data: abi.encodeCall(RfqControl.swap, (swapIntent, _buildBaselineCall(swapIntent, true)))
        });
        userOp.sessionKey = AUCTIONEER;

        // User signs the userOp
        // (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        // userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return userOp;
    }

    function _buildBaselineCall(
        SwapIntent memory swapIntent,
        bool shouldSucceed
    )
        internal
        view
        returns (BaselineCall memory)
    {
        bytes memory baselineData;
        uint256 value;
        uint256 amountOutMin = swapIntent.minAmountUserBuys;
        address[] memory path = new address[](2);
        path[0] = swapIntent.tokenUserSells;
        path[1] = swapIntent.tokenUserBuys;

        // Make amountOutMin way too high to cause baseline call to fail
        if (!shouldSucceed) amountOutMin *= 100; // 100x original amountOutMin

        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            path[0] = WETH_ADDRESS;
            value = swapIntent.amountUserSells;
            baselineData = abi.encodeCall(
                routerV2.swapExactETHForTokens,
                (
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    block.timestamp + 1 // deadline
                )
            );
        } else if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
            path[1] = WETH_ADDRESS;
            baselineData = abi.encodeCall(
                routerV2.swapExactTokensForETH,
                (
                    swapIntent.amountUserSells, // amountIn
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    block.timestamp + 1 // deadline
                )
            );
        } else {
            baselineData = abi.encodeCall(
                routerV2.swapExactTokensForTokens,
                (
                    swapIntent.amountUserSells, // amountIn
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    block.timestamp + 1 // deadline
                )
            );
        }

        return BaselineCall({ to: address(routerV2), data: baselineData, value: value });
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        UserOperation memory userOp,
        SwapIntent memory swapIntent
    )
        internal
        returns (address solverContract, SolverOperation memory solverOp)
    {
        // Make sure solver has 1 AtlETH bonded in Atlas
        uint256 bonded = atlas.balanceOfBonded(solverEOA);
        if (bonded < 1e18) {
            uint256 atlETHBalance = atlas.balanceOf(solverEOA);
            if (atlETHBalance < 1e18) {
                deal(solverEOA, 1e18 - atlETHBalance);
                atlas.deposit{ value: 1e18 - atlETHBalance }();
            }
            atlas.bond(1e18 - bonded);
        }

        // Deploy RFQ solver contract
        bytes32 salt = keccak256(abi.encodePacked(address(rfq), solverEOA, bidAmount, vm.getNonce(solverEOA)));
        RFQSolver solver = new RFQSolver{ salt: salt }(WETH_ADDRESS, address(atlas));

        // Create signed solverOp
        solverOp = _buildSolverOp(swapIntent, solverEOA, solverPK, address(solver), bidAmount, userOp);

        // Give solver contract enough tokenOut to fulfill user's SwapIntent
        if (swapIntent.tokenUserBuys != NATIVE_TOKEN) {
            deal(swapIntent.tokenUserBuys, address(solver), bidAmount);
        } else {
            deal(address(solver), bidAmount);
        }

        // Returns the address of the solver contract deployed here
        return (address(solver), solverOp);
    }

    function _buildSolverOp(
        SwapIntent memory swapIntent,
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount,
        UserOperation memory userOp
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        // Builds the SolverOperation
        solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeCall(RFQSolver.fulfillRFQ, (swapIntent)),
            solver: solverEOA,
            solverContract: address(solverContract),
            bidAmount: bidAmount,
            value: 0
        });

        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    // balanceOf helper that supports ERC20 and native token
    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function _setUpOperations(
        SwapIntent memory swapIntent,
        bool solverShouldSucceed,
        address from,
        uint256 msgValue
    )
        internal
        returns (
            address solverContract,
            SolverOperation[] memory solverOps,
            UserOperation memory userOp,
            DAppOperation memory dAppOp
        )
    {
        solverOps = new SolverOperation[](1);

        vm.startPrank(from);
        userOp = _setUpUser(swapIntent, from, msgValue);
        vm.stopPrank();

        vm.startPrank(solverOneEOA);
        SolverOperation memory solverOp;
        (solverContract, solverOp) = _setUpSolver(
            solverOneEOA,
            solverOnePK,
            swapIntent.tokenUserBuys == DAI_ADDRESS ? goodSolverBidDAI : goodSolverBidETH,
            userOp,
            swapIntent
        );

        RFQSolver(payable(solverContract)).setShouldSucceed(solverShouldSucceed);
        vm.stopPrank();

        // Builds the SolverOperation
        solverOps[0] = solverOp;

        // Frontend creates dAppOp calldata after seeing rest of data
        dAppOp = txBuilder.buildDAppOperation(AUCTIONEER, userOp, solverOps);
        dAppOp.bundler = from;

        // Auctioneer signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(AUCTIONEER_PK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function printBeforeBalances(SwapIntent memory swapIntent, address user, address solver) internal view {
        uint256 userSellBalanceBefore = _balanceOf(swapIntent.tokenUserSells, user);
        uint256 userBuyBalanceBefore = _balanceOf(swapIntent.tokenUserBuys, user);
        uint256 solverSellBalanceBefore = _balanceOf(swapIntent.tokenUserSells, solver);
        uint256 solverBuyBalanceBefore = _balanceOf(swapIntent.tokenUserBuys, solver);
        uint256 feeRecipientBuyBalanceBefore = _balanceOf(swapIntent.tokenUserBuys, FEE_RECIPIENT);

        assertGt(solverBuyBalanceBefore, swapIntent.minAmountUserBuys, "Not enough BUY tokens");

        console.log("\nBEFORE METACALL");
        console.log("User Sell balance", userSellBalanceBefore);
        console.log("User Buy balance", userBuyBalanceBefore);
        console.log("Solver Sell balance", solverSellBalanceBefore);
        console.log("Solver Buy balance", solverBuyBalanceBefore);
        console.log("Fee Recipient balance", feeRecipientBuyBalanceBefore);
    }

    function printAfterBalances(SwapIntent memory swapIntent, address user, address solver) internal view {
        uint256 userSellBalanceAfter = _balanceOf(swapIntent.tokenUserSells, user);
        uint256 userBuyBalanceAfter = _balanceOf(swapIntent.tokenUserBuys, user);
        uint256 solverSellBalanceAfter = _balanceOf(swapIntent.tokenUserSells, solver);
        uint256 solverBuyBalanceAfter = _balanceOf(swapIntent.tokenUserBuys, solver);
        uint256 feeRecipientBuyBalanceAfter = _balanceOf(swapIntent.tokenUserBuys, FEE_RECIPIENT);

        // assertGt(feeRecipientBuyBalanceAfter, 0, "Fee Recipient didn't get paid!");

        console.log("\nAFTER METACALL");
        console.log("User Sell balance", userSellBalanceAfter);
        console.log("User Buy balance", userBuyBalanceAfter);
        console.log("Solver Sell balance", solverSellBalanceAfter);
        console.log("Solver Buy balance", solverBuyBalanceAfter);
        console.log("Fee Recipient balance", feeRecipientBuyBalanceAfter);
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract RFQSolver is SolverBase {
    address internal constant NATIVE_TOKEN = address(0);
    bool internal s_shouldSucceed;

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {
        s_shouldSucceed = true; // should succeed by default, can be set to false
    }

    function shouldSucceed() public view returns (bool) {
        return s_shouldSucceed;
    }

    function setShouldSucceed(bool succeed) public {
        s_shouldSucceed = succeed;
    }

    function fulfillRFQ(SwapIntent calldata swapIntent) public view {
        require(s_shouldSucceed, "Solver failed intentionally");

        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            require(
                address(this).balance >= swapIntent.amountUserSells, "Did not receive expected amount of tokenUserBuys"
            );
        } else {
            require(
                IERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= swapIntent.amountUserSells,
                "Did not receive expected amount of tokenUserSells"
            );
        }
        // The solver bid representing user's minAmountUserBuys of tokenUserBuys is sent to the
        // Execution Environment in the payBids modifier logic which runs after this function ends.
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}
