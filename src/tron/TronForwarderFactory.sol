// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TronPaymentForwarder} from "./TronPaymentForwarder.sol";

/// @title TronForwarderFactory
/// @notice TRON variant of {ForwarderFactory}. TVM derives CREATE2 addresses with the prefix 0x41 instead of
///         Ethereum's 0xff, so OpenZeppelin's address prediction is wrong on TRON. The prefix is an immutable
///         constructor argument (0x41 on TRON, 0xff in EVM unit tests) and every deployment is checked against
///         the prediction, so a wrong prefix can never silently flush a different address.
contract TronForwarderFactory {
    /// @notice Hard upper bounds that protect merchants against misconfiguration.
    uint16 public constant MAX_FEE_BPS = 500; // 5 %
    uint64 public constant MAX_FEE_FIXED = 5_000_000; // 5 units of a 6-decimal stablecoin

    address public immutable implementation;
    bytes1 public immutable create2Prefix;

    event ForwarderDeployed(
        address indexed forwarder,
        address indexed merchant,
        address indexed feeRecipient,
        uint16 feeBps,
        uint64 feeFixed,
        bytes32 salt
    );

    error InvalidMerchant();
    error FeeTooHigh();
    error InvalidFeeRecipient();
    error InvalidPrefix();
    error PredictionMismatch(address predicted, address deployed);

    constructor(bytes1 prefix) {
        if (prefix != 0x41 && prefix != 0xff) revert InvalidPrefix();
        create2Prefix = prefix;
        implementation = address(new TronPaymentForwarder());
    }

    function computeAddress(address merchant, address feeRecipient, uint16 feeBps, uint64 feeFixed, bytes32 salt)
        public
        view
        returns (address)
    {
        return _predict(_args(merchant, feeRecipient, feeBps, feeFixed), salt);
    }

    function deploy(address merchant, address feeRecipient, uint16 feeBps, uint64 feeFixed, bytes32 salt)
        public
        returns (address forwarder)
    {
        bytes memory args = _args(merchant, feeRecipient, feeBps, feeFixed);
        forwarder = _predict(args, salt);
        if (forwarder.code.length != 0) return forwarder;

        address deployed = Clones.cloneDeterministicWithImmutableArgs(implementation, args, salt);
        if (deployed != forwarder) revert PredictionMismatch(forwarder, deployed);
        // forge-lint: disable-next-line(reentrancy-events)
        emit ForwarderDeployed(forwarder, merchant, feeRecipient, feeBps, feeFixed, salt);
    }

    function deployAndFlush(
        address merchant,
        address feeRecipient,
        uint16 feeBps,
        uint64 feeFixed,
        bytes32 salt,
        IERC20[] calldata tokens,
        bool includeNative
    ) external returns (address forwarder) {
        forwarder = deploy(merchant, feeRecipient, feeBps, feeFixed, salt);
        for (uint256 i = 0; i < tokens.length; ++i) {
            // forge-lint: disable-next-line(calls-loop, unused-return)
            TronPaymentForwarder(payable(forwarder)).flushToken(tokens[i]);
        }
        // forge-lint: disable-next-line(unused-return)
        if (includeNative) TronPaymentForwarder(payable(forwarder)).flushNative();
    }

    /// @dev Same init code as OpenZeppelin Clones (EIP-1167 with immutable args), hashed with our prefix.
    function _predict(bytes memory args, bytes32 salt) private view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"61",
                uint16(args.length + 0x2d),
                hex"3d81600a3d39f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3",
                args
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(create2Prefix, address(this), salt, initCodeHash)))));
    }

    /// @dev feeRecipient is required exactly when some fee is charged, so every fee-free merchant/salt has one address.
    function _args(address merchant, address feeRecipient, uint16 feeBps, uint64 feeFixed)
        private
        pure
        returns (bytes memory)
    {
        if (merchant == address(0)) revert InvalidMerchant();
        if (feeBps > MAX_FEE_BPS || feeFixed > MAX_FEE_FIXED) revert FeeTooHigh();
        if ((feeBps == 0 && feeFixed == 0) != (feeRecipient == address(0))) revert InvalidFeeRecipient();
        return abi.encodePacked(merchant, feeRecipient, feeBps, feeFixed);
    }
}
