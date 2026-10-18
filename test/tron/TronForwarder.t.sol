// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TronForwarderFactory} from "../../src/tron/TronForwarderFactory.sol";
import {TronPaymentForwarder} from "../../src/tron/TronPaymentForwarder.sol";
import {MockERC20, MockUSDT} from "../mocks/Mocks.sol";
import {MockTronUSDT, MockLyingToken, MockBlacklistToken} from "./mocks/TronMocks.sol";

/// @dev Runs on the EVM, so the factory is built with prefix 0xff; the 0x41 formula is checked off-chain and on Nile.
contract TronForwarderTest is Test {
    TronForwarderFactory factory;
    MockTronUSDT usdt;

    address merchant = makeAddr("merchant");
    address feeWallet = makeAddr("feeWallet");
    bytes32 salt = keccak256("tron-invoice-1");
    uint64 constant ONE = 1_000_000; // 1 USDT

    function setUp() public {
        factory = new TronForwarderFactory(0xff);
        usdt = new MockTronUSDT();
    }

    function _t(address a) internal pure returns (IERC20[] memory t) {
        t = new IERC20[](1);
        t[0] = IERC20(a);
    }

    function test_rejectsUnknownPrefix() public {
        vm.expectRevert(TronForwarderFactory.InvalidPrefix.selector);
        new TronForwarderFactory(0x00);
    }

    function test_safeERC20_wouldRevertOnTronUSDT() public {
        // documents WHY this variant exists
        usdt.mint(address(this), 10);
        vm.expectRevert();
        this.safeTransferHelper(IERC20(address(usdt)), merchant, 10);
    }

    function safeTransferHelper(IERC20 t, address to, uint256 a) external {
        SafeERC20.safeTransfer(t, to, a);
    }

    function test_prepaidPlan_forwardsEverything() public {
        address a = factory.computeAddress(merchant, address(0), 0, 0, salt);
        usdt.mint(a, 25 * ONE);
        assertEq(factory.deployAndFlush(merchant, address(0), 0, 0, salt, _t(address(usdt)), false), a);
        assertEq(usdt.balanceOf(merchant), 25 * ONE);
        assertEq(usdt.balanceOf(a), 0);
    }

    function test_onchainPlan_percentPlusFixed() public {
        // 1 % + 1 USDT on a 100 USDT payment -> fee 2 USDT
        address a = factory.computeAddress(merchant, feeWallet, 100, ONE, salt);
        usdt.mint(a, 100 * ONE);
        factory.deployAndFlush(merchant, feeWallet, 100, ONE, salt, _t(address(usdt)), false);
        assertEq(usdt.balanceOf(feeWallet), 2 * ONE);
        assertEq(usdt.balanceOf(merchant), 98 * ONE);
    }

    function test_fixedFeeCappedAtBalance() public {
        address a = factory.computeAddress(merchant, feeWallet, 100, ONE, salt);
        usdt.mint(a, ONE / 2);
        factory.deployAndFlush(merchant, feeWallet, 100, ONE, salt, _t(address(usdt)), false);
        assertEq(usdt.balanceOf(feeWallet), ONE / 2);
        assertEq(usdt.balanceOf(merchant), 0);
    }

    function test_paramsChangeAddress() public {
        address a = factory.computeAddress(merchant, feeWallet, 100, ONE, salt);
        assertTrue(a != factory.computeAddress(merchant, feeWallet, 100, ONE + 1, salt));
        assertTrue(a != factory.computeAddress(merchant, feeWallet, 101, ONE, salt));
        assertTrue(a != factory.computeAddress(makeAddr("other"), feeWallet, 100, ONE, salt));
    }

    function test_validation() public {
        vm.expectRevert(TronForwarderFactory.InvalidMerchant.selector);
        factory.computeAddress(address(0), address(0), 0, 0, salt);
        vm.expectRevert(TronForwarderFactory.FeeTooHigh.selector);
        factory.computeAddress(merchant, feeWallet, 0, 5_000_001, salt);
        vm.expectRevert(TronForwarderFactory.FeeTooHigh.selector);
        factory.computeAddress(merchant, feeWallet, 501, 0, salt);
        vm.expectRevert(TronForwarderFactory.InvalidFeeRecipient.selector);
        factory.computeAddress(merchant, address(0), 0, ONE, salt); // fixed fee needs a recipient
        vm.expectRevert(TronForwarderFactory.InvalidFeeRecipient.selector);
        factory.computeAddress(merchant, feeWallet, 0, 0, salt); // no fee -> no recipient
    }

    function test_configRoundTrip() public {
        address a = factory.deploy(merchant, feeWallet, 150, 1_234_567, salt);
        (address m, address f, uint16 bps, uint64 fixedFee) = TronPaymentForwarder(payable(a)).config();
        assertEq(m, merchant);
        assertEq(f, feeWallet);
        assertEq(bps, 150);
        assertEq(fixedFee, 1_234_567);
    }

    function test_deployIsIdempotent_reflushWorks() public {
        address a = factory.deployAndFlush(merchant, feeWallet, 100, ONE, salt, _t(address(usdt)), false);
        usdt.mint(a, 10 * ONE);
        assertEq(factory.deployAndFlush(merchant, feeWallet, 100, ONE, salt, _t(address(usdt)), false), a);
        assertEq(usdt.balanceOf(merchant), 10 * ONE - ONE - ONE / 10);
    }

    function test_worksWithStandardAndNoReturnTokens() public {
        MockERC20 usdc = new MockERC20();
        MockUSDT ethUsdt = new MockUSDT();
        address a = factory.computeAddress(merchant, address(0), 0, 0, salt);
        usdc.mint(a, 5);
        ethUsdt.mint(a, 7);
        IERC20[] memory t = new IERC20[](2);
        t[0] = IERC20(address(usdc));
        t[1] = IERC20(address(ethUsdt));
        factory.deployAndFlush(merchant, address(0), 0, 0, salt, t, false);
        assertEq(usdc.balanceOf(merchant), 5);
        assertEq(ethUsdt.balanceOf(merchant), 7);
    }

    function test_tokenThatMovesNothing_reverts() public {
        MockLyingToken bad = new MockLyingToken();
        address a = factory.computeAddress(merchant, address(0), 0, 0, salt);
        bad.mint(a, 5);
        vm.expectRevert(
            abi.encodeWithSelector(TronPaymentForwarder.TokenTransferFailed.selector, address(bad), merchant, 5)
        );
        factory.deployAndFlush(merchant, address(0), 0, 0, salt, _t(address(bad)), false);
    }

    function test_blacklistedMerchant_fundsStayInForwarder() public {
        MockBlacklistToken t = new MockBlacklistToken();
        address a = factory.computeAddress(merchant, address(0), 0, 0, salt);
        t.mint(a, 9);
        t.block_(merchant);
        vm.expectRevert();
        factory.deployAndFlush(merchant, address(0), 0, 0, salt, _t(address(t)), false);
        assertEq(t.balanceOf(a), 9); // not lost; no one else can move them either
    }

    function test_nativeTrx_percentOnly() public {
        address a = factory.computeAddress(merchant, feeWallet, 100, ONE, salt);
        vm.deal(a, 1000);
        factory.deployAndFlush(merchant, feeWallet, 100, ONE, salt, new IERC20[](0), true);
        assertEq(merchant.balance, 990);
        assertEq(feeWallet.balance, 10);
    }

    function test_implementationCannotBeUsedDirectly() public {
        TronPaymentForwarder impl = TronPaymentForwarder(payable(factory.implementation()));
        vm.expectRevert(TronPaymentForwarder.NotAClone.selector);
        impl.config();
    }

    function testFuzz_feeSplitConserves(uint96 amount, uint16 bps, uint64 fixedFee) public {
        bps = uint16(bound(bps, 0, 500));
        fixedFee = uint64(bound(fixedFee, 0, 5_000_000));
        address feeTo = (bps == 0 && fixedFee == 0) ? address(0) : feeWallet;
        address a = factory.computeAddress(merchant, feeTo, bps, fixedFee, salt);
        usdt.mint(a, amount);
        factory.deployAndFlush(merchant, feeTo, bps, fixedFee, salt, _t(address(usdt)), false);
        uint256 fee = feeTo == address(0) ? 0 : usdt.balanceOf(feeWallet);
        assertEq(usdt.balanceOf(merchant) + fee, amount);
        uint256 expected = uint256(amount) * bps / 10_000 + fixedFee;
        assertEq(fee, expected > amount ? amount : expected);
    }
}
