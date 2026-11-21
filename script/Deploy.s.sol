// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {GuardReactive} from "../src/GuardReactive.sol";
import {GuardVault} from "../src/GuardVault.sol";
import {MockMarket, MockToken} from "../src/MockMarket.sol";

abstract contract GuardTestnets is Script {
    uint256 internal constant LASNA = 5318007;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant BASE_SEPOLIA = 84532;

    error UnsupportedChain(uint256 chainId);

    function _proxy(uint256 chainId) internal pure returns (IPayable) {
        if (chainId == UNICHAIN_SEPOLIA) return IPayable(payable(0x775c9B990ADe401060B78D0e98684eEf8d2466C1));
        if (chainId == BASE_SEPOLIA) return IPayable(payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585));
        revert UnsupportedChain(chainId);
    }

    function _requireLasna() internal view {
        if (block.chainid != LASNA) revert UnsupportedChain(block.chainid);
    }
}

contract DeployReactive is GuardTestnets {
    function run() external returns (GuardReactive reactive) {
        _requireLasna();
        uint256 destination = vm.envUint("DESTINATION_CHAIN_ID");
        _proxy(destination);
        vm.startBroadcast(vm.envAddress("LASNA_OPERATOR"));
        reactive = new GuardReactive{value: vm.envUint("REACTIVE_FUNDING_WEI")}(destination);
        vm.stopBroadcast();
    }
}

contract DeployDestination is GuardTestnets {
    function run() external returns (MockToken base, MockToken quote, MockMarket market, GuardVault vault) {
        IPayable proxy = _proxy(block.chainid);
        address operator = vm.envAddress("DESTINATION_OPERATOR");
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        uint256 callbackFunding = vm.envUint("CALLBACK_FUNDING_WEI");
        vm.startBroadcast(operator);
        base = new MockToken("Guard Base", "GBASE", operator, 1_000 ether);
        quote = new MockToken("Guard Quote", "GQUOTE", operator, 100_000 ether);
        market = new MockMarket(base, quote, operator, 100 ether);
        quote.transfer(address(market), 100_000 ether);
        vault = new GuardVault{value: callbackFunding}(proxy, reactive, market);
        vm.stopBroadcast();
    }
}

contract ConfigureReactive is GuardTestnets {
    function run() external {
        _requireLasna();
        GuardReactive reactive = GuardReactive(payable(vm.envAddress("REACTIVE_ADDRESS")));
        vm.startBroadcast(vm.envAddress("LASNA_OPERATOR"));
        reactive.configure(vm.envAddress("VAULT_ADDRESS"), vm.envAddress("MARKET_ADDRESS"));
        vm.stopBroadcast();
    }
}
