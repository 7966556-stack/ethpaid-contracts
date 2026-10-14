// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PaymentForwarder} from "./PaymentForwarder.sol";

/// @title ForwarderFactory
/// @notice Computes and deploys non-custodial payment addresses ({PaymentForwarder} clones).
/// @dev The address of a payment forwarder is fully determined by (merchant, feeRecipient, feeBps, salt).
///      An address can be handed to a payer before anything is deployed; funds sent there can only ever be
///      forwarded according to those parameters. Deployment and flushing are permissionless.
contract ForwarderFactory {
    /// @notice Hard upper bound for the service fee (5%), protects merchants against misconfiguration.
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice The single {PaymentForwarder} implementation all clones delegate to.
    address public immutable implementation;

    event ForwarderDeployed(
        address indexed forwarder, address indexed merchant, address indexed feeRecipient, uint16 feeBps, bytes32 salt
    );

    error InvalidMerchant();
    error FeeTooHigh();
    error InvalidFeeRecipient();

    constructor() {
        implementation = address(new PaymentForwarder());
    }

    /// @notice Address of the payment forwarder for the given parameters (deployed or not).
    /// @dev Reverts on parameters that could never be deployed, so a backend can't hand out a dead address.
    function computeAddress(address merchant, address feeRecipient, uint16 feeBps, bytes32 salt)
        public
        view
        returns (address)
    {
        bytes memory args = _args(merchant, feeRecipient, feeBps);
        return Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt);
    }

    /// @notice Deploys the payment forwarder for the given parameters; returns the existing one if already deployed.
    function deploy(address merchant, address feeRecipient, uint16 feeBps, bytes32 salt)
        public
        returns (address forwarder)
    {
        bytes memory args = _args(merchant, feeRecipient, feeBps);
        forwarder = Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt);
        if (forwarder.code.length != 0) return forwarder;

        Clones.cloneDeterministicWithImmutableArgs(implementation, args, salt);
        // The only preceding call is CREATE2 of our own clone, which has no constructor code.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ForwarderDeployed(forwarder, merchant, feeRecipient, feeBps, salt);
    }

    /// @notice Deploys (if needed) and forwards the given tokens and, optionally, the native coin.
    function deployAndFlush(
        address merchant,
        address feeRecipient,
        uint16 feeBps,
        bytes32 salt,
        IERC20[] calldata tokens,
        bool includeNative
    ) external returns (address forwarder) {
        forwarder = deploy(merchant, feeRecipient, feeBps, salt);
        for (uint256 i = 0; i < tokens.length; ++i) {
            // forge-lint: disable-next-line(calls-loop, unused-return)
            PaymentForwarder(payable(forwarder)).flushToken(tokens[i]);
        }
        // forge-lint: disable-next-line(unused-return)
        if (includeNative) PaymentForwarder(payable(forwarder)).flushNative();
    }

    /// @dev Validates parameters and packs them as clone immutable args (42 bytes).
    ///      feeBps == 0 requires feeRecipient == address(0) so every "prepaid" merchant/salt has one canonical address.
    function _args(address merchant, address feeRecipient, uint16 feeBps) private pure returns (bytes memory) {
        if (merchant == address(0)) revert InvalidMerchant();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if ((feeBps == 0) != (feeRecipient == address(0))) revert InvalidFeeRecipient();
        return abi.encodePacked(merchant, feeRecipient, feeBps);
    }
}
