// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";

/// @notice Runs against real Ethereum mainnet state. Skipped unless ETH_RPC_URL is set.
///         ETH_RPC_URL=http://127.0.0.1:18545 forge test --match-contract MainnetFork -vv
contract MainnetForkTest is Test {
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    ForwarderFactory factory;
    address merchant = makeAddr("merchant");
    address feeWallet = makeAddr("feeWallet");
    address relayer = makeAddr("relayer");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        factory = new ForwarderFactory();
    }

    function _pay(IERC20 token, address to, uint256 amount) internal {
        deal(address(token), address(this), amount);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer");
    }

    function _flushGas(IERC20 token, address feeR, uint16 bps, bytes32 salt) internal returns (uint256 gasUsed) {
        IERC20[] memory t = new IERC20[](1);
        t[0] = token;
        vm.prank(relayer);
        uint256 g = gasleft();
        factory.deployAndFlush(merchant, feeR, bps, salt, t, false);
        gasUsed = g - gasleft();
    }

    function test_RealUsdt_BothPlans() public {
        bytes32 s1 = keccak256("usdt-prepaid");
        _pay(USDT, factory.computeAddress(merchant, address(0), 0, s1), 1_234_560_000);
        uint256 gPrepaid = _flushGas(USDT, address(0), 0, s1);
        assertEq(USDT.balanceOf(merchant), 1_234_560_000);

        bytes32 s2 = keccak256("usdt-onchain-fee");
        _pay(USDT, factory.computeAddress(merchant, feeWallet, 100, s2), 1_000_000_000);
        uint256 gFee = _flushGas(USDT, feeWallet, 100, s2);
        assertEq(USDT.balanceOf(feeWallet), 10_000_000);
        assertEq(USDT.balanceOf(merchant), 1_234_560_000 + 990_000_000);

        console2.log("USDT deployAndFlush gas, prepaid plan :", gPrepaid);
        console2.log("USDT deployAndFlush gas, on-chain fee :", gFee);
    }

    function test_RealUsdc_BothPlans() public {
        bytes32 s1 = keccak256("usdc-prepaid");
        _pay(USDC, factory.computeAddress(merchant, address(0), 0, s1), 500e6);
        uint256 gPrepaid = _flushGas(USDC, address(0), 0, s1);
        assertEq(USDC.balanceOf(merchant), 500e6);

        bytes32 s2 = keccak256("usdc-onchain-fee");
        _pay(USDC, factory.computeAddress(merchant, feeWallet, 80, s2), 500e6);
        uint256 gFee = _flushGas(USDC, feeWallet, 80, s2);
        assertEq(USDC.balanceOf(feeWallet), 4e6);

        console2.log("USDC deployAndFlush gas, prepaid plan :", gPrepaid);
        console2.log("USDC deployAndFlush gas, on-chain fee :", gFee);
    }
}
