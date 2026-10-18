// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Mimics Tether USDT on TRON (TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t): a successful transfer returns false.
///      Verified on mainnet with triggerconstantcontract on 18.10.2026.
contract MockTronUSDT {
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return false;
    }
}

/// @dev Returns true but moves nothing (broken or malicious token).
contract MockLyingToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Blacklists recipients like Tether/Circle: transfer to a blocked address reverts.
contract MockBlacklistToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function block_(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[to], "blacklisted");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Balance can be reduced by the issuer (like Tether's destroyBlackFunds).
contract MockShrinkToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burnFrom(address a, uint256 amount) external {
        balanceOf[a] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
