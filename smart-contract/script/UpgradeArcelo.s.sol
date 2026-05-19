// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Arcelo} from "../src/Arcelo.sol";

contract UpgradeArcelo is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (Arcelo newImplementation) {
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        address payable proxy = payable(vm.envAddress("ARCELO_PROXY"));
        address oldImplementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));

        require(block.chainid == expectedChainId, "Unexpected chain id");

        vm.startBroadcast(ownerKey);
        newImplementation = new Arcelo();
        Arcelo(proxy).upgradeToAndCall(address(newImplementation), "");
        vm.stopBroadcast();

        console2.log("Proxy:", proxy);
        console2.log("Old implementation:", oldImplementation);
        console2.log("New implementation:", address(newImplementation));
        console2.log("Chain id:", block.chainid);
    }
}
