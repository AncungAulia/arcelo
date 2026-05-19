// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Arcelo} from "../src/Arcelo.sol";

contract ConfigureCeloMainnet is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        Arcelo arcelo = Arcelo(payable(vm.envAddress("ARCELO_PROXY")));
        address usdcToken = vm.envAddress("USDC_TOKEN");
        uint256 usdcMinBet = vm.envUint("USDC_MIN_BET");
        uint256 usdcMaxBet = vm.envUint("USDC_MAX_BET");

        require(block.chainid == expectedChainId, "Unexpected chain id");

        vm.startBroadcast(ownerKey);
        arcelo.setSupportedToken(usdcToken, true, usdcMinBet, usdcMaxBet);
        vm.stopBroadcast();

        console2.log("Configured USDC token:", usdcToken);
        console2.log("  minBet:", usdcMinBet);
        console2.log("  maxBet:", usdcMaxBet);
    }
}
