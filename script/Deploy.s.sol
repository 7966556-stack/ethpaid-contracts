// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";

/// @notice Deploys ForwarderFactory through the standard CREATE2 deployer
///         (0x4e59b44847b379578588920ca78fbf26c0b4956c), so the factory — and therefore every payment
///         address — is identical on every EVM chain. A payment sent on the "wrong" EVM network can then
///         still be forwarded to the merchant once the factory exists there.
contract Deploy is Script {
    bytes32 public constant SALT = keccak256("ETHPAID ForwarderFactory v1");

    function run() external returns (ForwarderFactory factory) {
        address predicted = vm.computeCreate2Address(SALT, keccak256(type(ForwarderFactory).creationCode));
        if (predicted.code.length != 0) {
            console2.log("Already deployed at", predicted);
            return ForwarderFactory(predicted);
        }
        vm.startBroadcast();
        factory = new ForwarderFactory{salt: SALT}();
        vm.stopBroadcast();
        require(address(factory) == predicted, "unexpected address");
        console2.log("ForwarderFactory  ", address(factory));
        console2.log("Implementation    ", factory.implementation());
    }
}
