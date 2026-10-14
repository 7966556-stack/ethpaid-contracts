// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title PaymentForwarder
/// @notice Non-custodial payment address. Every clone has three immutable arguments baked into its
///         bytecode (and therefore into its CREATE2 address): the merchant wallet, the fee recipient
///         and the fee in basis points. Funds can only ever leave to those two wallets.
/// @dev Deployed once as an implementation; used only through EIP-1167 clones created by
///      {ForwarderFactory}. There is no owner, no admin function and no upgrade path.
///      All flush functions are permissionless: anyone (including the merchant) may call them.
contract PaymentForwarder {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Address of the implementation itself, used to forbid calls that are not made through a clone.
    address private immutable _self;

    /// @notice Emitted when a balance is forwarded. `token` is address(0) for the native coin.
    event Flushed(address indexed token, address indexed merchant, uint256 merchantAmount, uint256 feeAmount);

    error NotAClone();

    constructor() {
        _self = address(this);
    }

    /// @notice Accepts the native coin (ETH, BNB, POL...). Kept empty so plain transfers stay cheap.
    receive() external payable {}

    /// @notice Immutable configuration of this payment address.
    function config() public view returns (address merchant, address feeRecipient, uint16 feeBps) {
        if (address(this) == _self) revert NotAClone();
        bytes memory args = Clones.fetchCloneArgs(address(this));
        // args = abi.encodePacked(address merchant, address feeRecipient, uint16 feeBps) — 42 bytes
        assembly ("memory-safe") {
            let p := add(args, 0x20)
            merchant := shr(96, mload(p))
            feeRecipient := shr(96, mload(add(p, 20)))
            feeBps := shr(240, mload(add(p, 40)))
        }
    }

    /// @notice Forwards the whole balance of `token`: fee to the fee recipient, the rest to the merchant.
    /// @dev No-op (no event) when the balance is zero. Works with non-standard tokens such as USDT.
    function flushToken(IERC20 token) public returns (uint256 merchantAmount, uint256 feeAmount) {
        (address merchant, address feeRecipient, uint16 feeBps) = config();
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return (0, 0);

        feeAmount = (balance * feeBps) / BPS_DENOMINATOR;
        merchantAmount = balance - feeAmount;

        // Only a view call (balanceOf) precedes this event; all transfers come after it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Flushed(address(token), merchant, merchantAmount, feeAmount);

        if (feeAmount != 0) token.safeTransfer(feeRecipient, feeAmount);
        token.safeTransfer(merchant, merchantAmount);
    }

    /// @notice Forwards several tokens in one call.
    function flushTokens(IERC20[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; ++i) {
            // Batch is all-or-nothing by design; the caller chooses which tokens to include.
            // forge-lint: disable-next-line(calls-loop, unused-return)
            flushToken(tokens[i]);
        }
    }

    /// @notice Forwards the whole native-coin balance.
    /// @dev Reverts if the merchant wallet cannot receive the native coin; funds then stay here until it can.
    function flushNative() public returns (uint256 merchantAmount, uint256 feeAmount) {
        (address merchant, address feeRecipient, uint16 feeBps) = config();
        uint256 balance = address(this).balance;
        if (balance == 0) return (0, 0);

        feeAmount = (balance * feeBps) / BPS_DENOMINATOR;
        merchantAmount = balance - feeAmount;

        // forge-lint: disable-next-line(reentrancy-events)
        emit Flushed(address(0), merchant, merchantAmount, feeAmount);

        // Recipients are fixed in the clone's immutable args, not chosen by the caller.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (feeAmount != 0) Address.sendValue(payable(feeRecipient), feeAmount);
        // forge-lint: disable-next-line(arbitrary-send-eth)
        Address.sendValue(payable(merchant), merchantAmount);
    }
}
