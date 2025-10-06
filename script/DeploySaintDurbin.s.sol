// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/SaintDurbin.sol";

contract DeploySaintDurbin is Script {
    function run() external {
        // Configuration - ALL MUST BE SET BEFORE DEPLOYMENT
        address emergencyOperator = vm.envAddress("EMERGENCY_OPERATOR");
        address drainAddress = vm.envAddress("DRAIN_ADDRESS");
        bytes32 drainSs58Address = vm.envBytes32("DRAIN_SS58_ADDRESS");
        bytes32 validatorHotkey = vm.envBytes32("VALIDATOR_HOTKEY");
        uint16 validatorUid = uint16(vm.envUint("VALIDATOR_UID"));
        bytes32 thisSs58PublicKey = vm.envBytes32("CONTRACT_SS58_KEY");
        uint16 netuid = uint16(vm.envUint("NETUID"));

        bytes32[] memory recipientColdkey = new bytes32[];

        recipientColdkey = vm.envBytes32("RECIPIENT");

        // Log configuration
        console.log("Deploying SaintDurbin with:");
        console.log("Emergency Operator:", emergencyOperator);
        console.log("Drain Address:", drainAddress);
        console.log("Drain SS58 Address:", vm.toString(drainSs58Address));
        console.log("Validator Hotkey:", vm.toString(validatorHotkey));
        console.log("Validator UID:", validatorUid);
        console.log("Contract SS58 Key:", vm.toString(thisSs58PublicKey));
        console.log("NetUID:", netuid);
        console.log("Recipient:", recipientColdkey);

        // Deploy the contract
        vm.startBroadcast();

        SaintDurbin saintDurbin = new SaintDurbin(
            emergencyOperator,
            drainAddress,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            thisSs58PublicKey,
            netuid,
            recipientColdkey,
        );

        vm.stopBroadcast();

        console.log("SaintDurbin deployed at:", address(saintDurbin));
    }
}
