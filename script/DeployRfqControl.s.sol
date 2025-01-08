// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { RfqControl } from "src/rfq/RfqControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";

contract DeployRfqControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING RFQ DAPP CONTROL ===\n");

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t\t\t", deployer);

        address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
        address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");
        address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        uint256 fee = vm.envUint("FEE");

        require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
        require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");
        require(auctioneer != address(0), "AUCTIONEER_ADDRESS is not set");
        require(feeRecipient != address(0), "FEE_RECIPIENT_ADDRESS is not set");
        require(fee != 0, "FEE is not set");

        console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
        console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
        console.log("Adding Auctioneer as whitelisted signatory: \t", auctioneer);
        console.log("Fee recipient: \t\t\t\t", feeRecipient);
        console.log("Fee: \t\t\t\t\t", fee);
        console.log("\n");

        console.log("Deploying from deployer Account...");

        vm.startBroadcast(deployerPrivateKey);

        RfqControl rfqControl = new RfqControl(atlasAddress, feeRecipient, fee);

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(rfqControl));
        AtlasVerification(atlasVerificationAddress).addSignatory(address(rfqControl), auctioneer);

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("RFQ DAppControl: \t\t\t", address(rfqControl));
        console.log("\n");
    }
}
