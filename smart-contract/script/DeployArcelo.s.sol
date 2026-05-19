// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Arcelo} from "../src/Arcelo.sol";

contract DeployArcelo is Script {
    function run() external returns (Arcelo proxyArcelo, Arcelo implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        address owner = vm.envAddress("ARCELO_OWNER");
        address backendSigner = vm.envAddress("BACKEND_SIGNER");
        uint256 genesisWeekStart = vm.envUint("GENESIS_WEEK_START");
        uint256 maxSessionDuration = vm.envUint("MAX_SESSION_DURATION");
        address usdcToken = vm.envAddress("USDC_TOKEN");
        uint256 usdcMinBet = vm.envUint("USDC_MIN_BET");
        uint256 usdcMaxBet = vm.envUint("USDC_MAX_BET");

        require(block.chainid == expectedChainId, "Unexpected chain id");

        vm.startBroadcast(deployerKey);
        implementation = new Arcelo();
        bytes memory initData = abi.encodeCall(
            Arcelo.initialize,
            (owner, genesisWeekStart, backendSigner, maxSessionDuration, usdcToken, usdcMinBet, usdcMaxBet)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vm.stopBroadcast();

        proxyArcelo = Arcelo(payable(address(proxy)));
        console2.log("Arcelo proxy:", address(proxyArcelo));
        console2.log("Arcelo implementation:", address(implementation));
        console2.log("Owner:", owner);
        console2.log("Backend signer:", backendSigner);
        console2.log("Genesis week start:", genesisWeekStart);
        console2.log("Max session duration:", maxSessionDuration);
        console2.log("USDC token:", usdcToken);
        console2.log("USDC min bet:", usdcMinBet);
        console2.log("USDC max bet:", usdcMaxBet);
        console2.log("Chain id:", block.chainid);
    }
}
