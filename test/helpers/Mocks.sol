// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Minimal honest ERC-20 standing in for IMD at its mainnet address (etched in tests).
contract MockIMD {
    string public constant name = "IdentityMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Records a paid request the way the IMD Intake does: pulls the price, returns an id.
contract MockIntake is IIntake {
    address public immutable asset;
    uint256 public immutable price;
    uint256 public count;
    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;

    constructor(address asset_, uint256 price_) {
        asset = asset_;
        price = price_;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset_, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        require(asset_ == asset && amount >= price, "PriceNotMet");
        (bool ok,) = asset.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(ok, "pull");
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        requestId = keccak256(abi.encode(++count, msg.sender));
    }

    /// @dev Delivers a result as the control plane would, through the recorded callback.
    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature) external {
        (bool ok, bytes memory ret) =
            lastCallback.target.call(abi.encodeWithSelector(lastCallback.selector, requestId, a, signature));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
