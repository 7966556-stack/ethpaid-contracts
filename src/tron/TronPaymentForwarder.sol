// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title TronPaymentForwarder
/// @notice TRON variant of {PaymentForwarder}. Same guarantees — funds can only ever leave to the merchant wallet and
///         the fee recipient baked into the clone — with two TRON-specific differences:
///         1. USDT on TRON returns `false` from a successful `transfer`, so OpenZeppelin SafeERC20 would revert.
///            Transfers are accepted when the call does not revert and this contract's balance dropped by exactly
///            the amount sent (return data is ignored).
///         2. An optional fixed fee per flush (`feeFixed`, token units) covers TRON's per-transfer energy cost.
///         3. Token fees are ACCRUED, not sent on every flush: each USDT transfer costs ~64k energy on TRON, so a
///            second transfer per payment would double the cost. The merchant's share always leaves immediately and
///            in full; the fee stays here, booked in `accruedFee`, until anyone calls {collectFees}, which can only
///            send it to the fee recipient. The merchant's money is never held back.
/// @dev Immutable args: abi.encodePacked(address merchant, address feeRecipient, uint16 feeBps, uint64 feeFixed),
///      50 bytes. No owner, no admin function, no upgrade path; all functions are permissionless.
contract TronPaymentForwarder {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant DUST = 1;

    address private immutable _self;

    /// @notice Emitted when a balance is forwarded. `token` is address(0) for TRX.
    event Flushed(address indexed token, address indexed merchant, uint256 merchantAmount, uint256 feeAmount);
    /// @notice Emitted when accrued token fees are sent to the fee recipient.
    event FeesCollected(address indexed token, address indexed feeRecipient, uint256 amount);

    /// @notice Fees booked per token and not yet sent to the fee recipient. Never paid to anyone else.
    mapping(address token => uint256) public accruedFee;

    error NotAClone();
    error TokenTransferFailed(address token, address to, uint256 amount);

    constructor() {
        _self = address(this);
    }

    receive() external payable {}

    /// @notice Immutable configuration of this payment address.
    function config() public view returns (address merchant, address feeRecipient, uint16 feeBps, uint64 feeFixed) {
        if (address(this) == _self) revert NotAClone();
        bytes memory args = Clones.fetchCloneArgs(address(this));
        assembly ("memory-safe") {
            let p := add(args, 0x20)
            merchant := shr(96, mload(p))
            feeRecipient := shr(96, mload(add(p, 20)))
            feeBps := shr(240, mload(add(p, 40)))
            feeFixed := shr(192, mload(add(p, 42)))
        }
    }

    /// @notice Fee for forwarding `balance` of a token: percentage plus the fixed part, never more than the balance.
    function feeFor(uint256 balance) public view returns (uint256 fee) {
        (,, uint16 feeBps, uint64 feeFixed) = config();
        fee = (balance * feeBps) / BPS_DENOMINATOR + feeFixed;
        if (fee > balance) fee = balance;
    }

    /// @notice Forwards everything that is not an already-booked fee: the merchant share goes out now, the new fee
    ///         is booked in {accruedFee}.
    function flushToken(IERC20 token) public returns (uint256 merchantAmount, uint256 feeAmount) {
        (address merchant,,,) = config();
        uint256 booked = accruedFee[address(token)];
        uint256 balance = token.balanceOf(address(this));
        if (balance <= booked) return (0, 0);
        uint256 available = balance - booked;

        feeAmount = feeFor(available);
        merchantAmount = available - feeAmount;
        if (feeAmount != 0) accruedFee[address(token)] = booked + feeAmount;

        // Only view calls precede this event; the single transfer comes after it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Flushed(address(token), merchant, merchantAmount, feeAmount);

        if (merchantAmount != 0) _transfer(token, merchant, merchantAmount);
    }

    /// @notice Sends the accrued fee of `token` to the fee recipient. Anyone may call it; the recipient is fixed.
    /// @dev Keeps DUST (1 base unit) booked so the storage slot and the token balance stay non-zero: on TRON,
    ///      turning a zero slot non-zero costs ~2x energy (payer's USDT transfer ~130k instead of ~64k, and +15k for
    ///      our next flush). The dust is part of the fee and is collected in a later round.
    function collectFees(IERC20 token) public returns (uint256 amount) {
        (, address feeRecipient,,) = config();
        uint256 booked = accruedFee[address(token)];
        uint256 balance = token.balanceOf(address(this));
        if (booked > balance) booked = balance; // token balance shrank externally (e.g. issuer action)
        if (booked <= DUST) return 0;
        amount = booked - DUST;
        accruedFee[address(token)] = DUST;

        // forge-lint: disable-next-line(reentrancy-events)
        emit FeesCollected(address(token), feeRecipient, amount);
        _transfer(token, feeRecipient, amount);
    }

    function flushTokens(IERC20[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; ++i) {
            // forge-lint: disable-next-line(calls-loop, unused-return)
            flushToken(tokens[i]);
        }
    }

    /// @notice Forwards the whole TRX balance. Only the percentage fee applies (feeFixed is in token units).
    function flushNative() public returns (uint256 merchantAmount, uint256 feeAmount) {
        (address merchant, address feeRecipient, uint16 feeBps,) = config();
        uint256 balance = address(this).balance;
        if (balance == 0) return (0, 0);

        feeAmount = (balance * feeBps) / BPS_DENOMINATOR;
        merchantAmount = balance - feeAmount;

        // forge-lint: disable-next-line(reentrancy-events)
        emit Flushed(address(0), merchant, merchantAmount, feeAmount);

        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (feeAmount != 0) Address.sendValue(payable(feeRecipient), feeAmount);
        // forge-lint: disable-next-line(arbitrary-send-eth)
        Address.sendValue(payable(merchant), merchantAmount);
    }

    /// @dev `transfer` that tolerates TRON USDT (returns false on success) and tokens without a return value:
    ///      success = the call did not revert AND our balance decreased by exactly `amount`.
    function _transfer(IERC20 token, address to, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        // Exact balance check is the point: it is how we detect a transfer that silently did nothing.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (!ok || token.balanceOf(address(this)) + amount != before) {
            revert TokenTransferFailed(address(token), to, amount);
        }
    }
}
