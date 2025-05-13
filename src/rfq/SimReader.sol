// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

error SimulationSuccess(uint256 amountOut);

interface ISimulator {
    function simulate(bytes calldata action) external returns (uint256);
}

library SimReader {
    bytes4 constant SIM_SELECTOR = 0xc2c08e32; // SimulationSuccess.selector

    function quote(address simulator, bytes memory action)
        internal
        returns (uint256 amountOut)
    {
        try ISimulator(simulator).simulate(action) returns (uint256 result) {
            // If we get here, the simulation didn't revert
            revert("Simulation did not revert");
        } catch (bytes memory revertData) {
            // Check if this is our expected revert
            if (revertData.length >= 4) {
                bytes4 errorSelector;
                assembly {
                    errorSelector := mload(add(revertData, 32))
                }
                if (errorSelector == SIM_SELECTOR) {
                    // Extract the amount out from the revert data
                    assembly {
                        let dataLocation := add(revertData, 0x20)
                        amountOut := mload(add(dataLocation, sub(mload(revertData), 32)))
                    }
                    return amountOut;
                }
            }
            // Different revert: bubble it up
            assembly { revert(add(revertData, 32), mload(revertData)) }
        }
    }
} 