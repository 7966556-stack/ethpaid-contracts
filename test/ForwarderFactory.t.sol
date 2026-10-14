// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {PaymentForwarder} from "../src/PaymentForwarder.sol";
import {MockERC20, MockUSDT, MockFalseToken, RejectNative} from "./mocks/Mocks.sol";

contract ForwarderFactoryTest is Test {
    ForwarderFactory factory;
    MockERC20 usdc;
    MockUSDT usdt;

    address merchant = makeAddr("merchant");
    address feeWallet = makeAddr("feeWallet");
    address payer = makeAddr("payer");
    address stranger = makeAddr("stranger");
    bytes32 salt = keccak256("invoice-0001");

    event ForwarderDeployed(
        address indexed forwarder, address indexed merchant, address indexed feeRecipient, uint16 feeBps, bytes32 salt
    );
    event Flushed(address indexed token, address indexed merchant, uint256 merchantAmount, uint256 feeAmount);

    function setUp() public {
        factory = new ForwarderFactory();
        usdc = new MockERC20();
        usdt = new MockUSDT();
    }

    function _tokens(address a) internal pure returns (IERC20[] memory t) {
        t = new IERC20[](1);
        t[0] = IERC20(a);
    }

    // ---------------------------------------------------------------- addresses

    function test_ComputeMatchesDeploy() public {
        address predicted = factory.computeAddress(merchant, feeWallet, 100, salt);
        assertEq(predicted.code.length, 0);

        vm.expectEmit(true, true, true, true);
        emit ForwarderDeployed(predicted, merchant, feeWallet, 100, salt);
        address deployed = factory.deploy(merchant, feeWallet, 100, salt);

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
    }

    function test_DeployIsIdempotent() public {
        address a = factory.deploy(merchant, address(0), 0, salt);
        vm.recordLogs();
        address b = factory.deploy(merchant, address(0), 0, salt);
        assertEq(a, b);
        assertEq(vm.getRecordedLogs().length, 0, "second deploy must not emit");
    }

    function test_AddressDependsOnEveryParameter() public view {
        address base = factory.computeAddress(merchant, feeWallet, 100, salt);
        assertTrue(base != factory.computeAddress(stranger, feeWallet, 100, salt), "merchant");
        assertTrue(base != factory.computeAddress(merchant, stranger, 100, salt), "fee recipient");
        assertTrue(base != factory.computeAddress(merchant, feeWallet, 101, salt), "fee bps");
        assertTrue(base != factory.computeAddress(merchant, feeWallet, 100, bytes32(uint256(salt) + 1)), "salt");
    }

    function test_ConfigReadsImmutableArgs() public {
        address f = factory.deploy(merchant, feeWallet, 250, salt);
        (address m, address r, uint16 bps) = PaymentForwarder(payable(f)).config();
        assertEq(m, merchant);
        assertEq(r, feeWallet);
        assertEq(bps, 250);
    }

    function test_ImplementationCannotBeUsedDirectly() public {
        PaymentForwarder impl = PaymentForwarder(payable(factory.implementation()));
        vm.expectRevert(PaymentForwarder.NotAClone.selector);
        impl.config();
        vm.expectRevert(PaymentForwarder.NotAClone.selector);
        impl.flushToken(IERC20(address(usdc)));
        vm.expectRevert(PaymentForwarder.NotAClone.selector);
        impl.flushNative();
    }

    // ---------------------------------------------------------------- validation

    function test_RevertZeroMerchant() public {
        vm.expectRevert(ForwarderFactory.InvalidMerchant.selector);
        factory.computeAddress(address(0), address(0), 0, salt);
        vm.expectRevert(ForwarderFactory.InvalidMerchant.selector);
        factory.deploy(address(0), address(0), 0, salt);
    }

    function test_RevertFeeTooHigh() public {
        vm.expectRevert(ForwarderFactory.FeeTooHigh.selector);
        factory.computeAddress(merchant, feeWallet, 501, salt);
        vm.expectRevert(ForwarderFactory.FeeTooHigh.selector);
        factory.deploy(merchant, feeWallet, 501, salt);
    }

    function test_MaxFeeAllowed() public {
        factory.deploy(merchant, feeWallet, 500, salt);
    }

    function test_RevertFeeWithoutRecipient() public {
        vm.expectRevert(ForwarderFactory.InvalidFeeRecipient.selector);
        factory.computeAddress(merchant, address(0), 100, salt);
    }

    function test_RevertRecipientWithoutFee() public {
        vm.expectRevert(ForwarderFactory.InvalidFeeRecipient.selector);
        factory.computeAddress(merchant, feeWallet, 0, salt);
    }

    // ---------------------------------------------------------------- tokens

    function test_PrepaidPlan_PaymentBeforeDeploy_FullAmountToMerchant() public {
        address payAddr = factory.computeAddress(merchant, address(0), 0, salt);
        usdc.mint(payer, 100e6);
        vm.prank(payer);
        usdc.transfer(payAddr, 100e6); // payer sends to a not-yet-deployed address

        vm.prank(stranger); // anyone may trigger forwarding
        factory.deployAndFlush(merchant, address(0), 0, salt, _tokens(address(usdc)), false);

        assertEq(usdc.balanceOf(merchant), 100e6);
        assertEq(usdc.balanceOf(payAddr), 0);
    }

    function test_OnchainFeePlan_SplitsPayment() public {
        address payAddr = factory.computeAddress(merchant, feeWallet, 100, salt); // 1%
        usdc.mint(payAddr, 250e6);

        vm.expectEmit(true, true, false, true, payAddr);
        emit Flushed(address(usdc), merchant, 247.5e6, 2.5e6);
        factory.deployAndFlush(merchant, feeWallet, 100, salt, _tokens(address(usdc)), false);

        assertEq(usdc.balanceOf(merchant), 247.5e6);
        assertEq(usdc.balanceOf(feeWallet), 2.5e6);
        assertEq(usdc.balanceOf(payAddr), 0);
    }

    function test_UsdtWithoutReturnValue() public {
        address payAddr = factory.computeAddress(merchant, feeWallet, 50, salt); // 0.5%
        usdt.mint(payAddr, 1_000e6);
        factory.deployAndFlush(merchant, feeWallet, 50, salt, _tokens(address(usdt)), false);
        assertEq(usdt.balanceOf(merchant), 995e6);
        assertEq(usdt.balanceOf(feeWallet), 5e6);
    }

    function test_TokenReturningFalseReverts_FundsStay() public {
        MockFalseToken bad = new MockFalseToken();
        address payAddr = factory.computeAddress(merchant, address(0), 0, salt);
        bad.mint(payAddr, 10);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        factory.deployAndFlush(merchant, address(0), 0, salt, _tokens(address(bad)), false);
        assertEq(bad.balanceOf(payAddr), 10);
    }

    function test_SeveralPaymentsThenOneFlush_StaticAddress() public {
        address payAddr = factory.deploy(merchant, address(0), 0, salt);
        usdc.mint(payAddr, 10e6);
        usdc.mint(payAddr, 20e6);
        usdc.mint(payAddr, 30e6);
        PaymentForwarder(payable(payAddr)).flushToken(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(merchant), 60e6);

        usdc.mint(payAddr, 5e6); // address keeps working after the first flush
        PaymentForwarder(payable(payAddr)).flushToken(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(merchant), 65e6);
    }

    function test_FlushZeroBalanceIsNoop() public {
        address payAddr = factory.deploy(merchant, feeWallet, 100, salt);
        vm.recordLogs();
        (uint256 m, uint256 f) = PaymentForwarder(payable(payAddr)).flushToken(IERC20(address(usdc)));
        assertEq(m + f, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_FlushTokensBatch() public {
        address payAddr = factory.deploy(merchant, address(0), 0, salt);
        usdc.mint(payAddr, 7e6);
        usdt.mint(payAddr, 9e6);
        IERC20[] memory t = new IERC20[](2);
        t[0] = IERC20(address(usdc));
        t[1] = IERC20(address(usdt));
        PaymentForwarder(payable(payAddr)).flushTokens(t);
        assertEq(usdc.balanceOf(merchant), 7e6);
        assertEq(usdt.balanceOf(merchant), 9e6);
    }

    function test_WrongTokenAlsoGoesToMerchant() public {
        MockERC20 other = new MockERC20();
        address payAddr = factory.computeAddress(merchant, feeWallet, 100, salt);
        other.mint(payAddr, 1e6);
        factory.deployAndFlush(merchant, feeWallet, 100, salt, _tokens(address(other)), false);
        assertEq(other.balanceOf(merchant), 0.99e6);
        assertEq(other.balanceOf(feeWallet), 0.01e6);
    }

    // ---------------------------------------------------------------- native coin

    function test_NativeBeforeDeploy_PlainTransferWorks() public {
        address payAddr = factory.computeAddress(merchant, feeWallet, 100, salt);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool ok,) = payAddr.call{value: 1 ether, gas: 2300}(""); // no code yet: even a 2300-gas stipend works
        assertTrue(ok);

        factory.deployAndFlush(merchant, feeWallet, 100, salt, new IERC20[](0), true);
        assertEq(merchant.balance, 0.99 ether);
        assertEq(feeWallet.balance, 0.01 ether);
        assertEq(payAddr.balance, 0);
    }

    function test_NativeAfterDeploy() public {
        address payAddr = factory.deploy(merchant, address(0), 0, salt);
        vm.deal(payer, 2 ether);
        vm.prank(payer);
        Address.sendValue(payable(payAddr), 2 ether);
        PaymentForwarder(payable(payAddr)).flushNative();
        assertEq(merchant.balance, 2 ether);
    }

    function test_NativeToRejectingMerchantReverts_FundsStay() public {
        address rejecting = address(new RejectNative());
        address payAddr = factory.deploy(rejecting, address(0), 0, salt);
        vm.deal(payAddr, 1 ether);
        vm.expectRevert();
        PaymentForwarder(payable(payAddr)).flushNative();
        assertEq(payAddr.balance, 1 ether);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_SplitIsExactAndMerchantFavourable(uint128 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, factory.MAX_FEE_BPS()));
        address payAddr = factory.computeAddress(merchant, feeWallet, feeBps, salt);
        usdc.mint(payAddr, amount);
        factory.deployAndFlush(merchant, feeWallet, feeBps, salt, _tokens(address(usdc)), false);

        uint256 expectedFee = (uint256(amount) * feeBps) / 10_000;
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
        assertEq(usdc.balanceOf(merchant), uint256(amount) - expectedFee);
        assertEq(usdc.balanceOf(payAddr), 0);
    }

    function testFuzz_OnlyConfiguredWalletsEverReceive(address caller, uint96 amount, bytes32 s) public {
        vm.assume(caller != merchant && caller != feeWallet);
        address payAddr = factory.computeAddress(merchant, feeWallet, 100, s);
        usdc.mint(payAddr, amount);
        vm.deal(payAddr, amount);
        vm.assume(caller.code.length == 0 && caller != payAddr);

        vm.prank(caller);
        factory.deployAndFlush(merchant, feeWallet, 100, s, _tokens(address(usdc)), true);

        assertEq(usdc.balanceOf(caller), 0);
        assertEq(usdc.balanceOf(merchant) + usdc.balanceOf(feeWallet), amount);
        assertEq(merchant.balance + feeWallet.balance, amount);
    }
}
