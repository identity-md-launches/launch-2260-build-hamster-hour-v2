// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake, IIntakeWithFailure} from "../../src/interfaces/IIntake.sol";
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

/// @dev Behaves like the IMD Intake v2 (imd.fun/docs, "Pay onchain" / "What comes back"): pulls the
/// price, returns an id, and later calls the recorded callback or failure hook with exactly the
/// documented 200,000 gas stipend inside a try, recording `delivered`.
contract MockIntake is IIntake, IIntakeWithFailure {
    uint256 public constant CALLBACK_GAS = 200_000;
    address public immutable asset;
    uint256 public immutable price;
    uint256 public count;
    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;
    bytes4 public lastFailureSelector;
    bool public delivered;
    uint256 public lastGasUsed;
    /// @dev When false, `requestWithFailure` reverts as an Intake without it would.
    bool public offersFailureHook = true;

    constructor(address asset_, uint256 price_) {
        asset = asset_;
        price = price_;
    }

    function setOffersFailureHook(bool on) external {
        offersFailureHook = on;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset_, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        return _request(action, body, callback, bytes4(0), asset_, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset_,
        uint256 amount
    ) external returns (bytes32 requestId) {
        require(offersFailureHook, "no such function");
        return _request(action, body, callback, onFailure, asset_, amount);
    }

    function _request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset_,
        uint256 amount
    ) private returns (bytes32 requestId) {
        require(asset_ == asset && amount >= price, "PriceNotMet");
        (bool ok,) = asset.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(ok, "pull");
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        lastFailureSelector = onFailure;
        requestId = keccak256(abi.encode(++count, msg.sender));
    }

    /// @dev Delivers a result as the control plane does: 200,000 gas, inside a try. Never reverts.
    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok)
    {
        uint256 before = gasleft();
        (ok,) = lastCallback.target.call{gas: CALLBACK_GAS}(
            abi.encodeWithSelector(lastCallback.selector, requestId, a, signature)
        );
        lastGasUsed = before - gasleft();
        delivered = ok;
    }

    /// @dev Delivers with unlimited gas and bubbles the revert, to read the callback's own error.
    function deliverStrict(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        (bool ok, bytes memory ret) =
            lastCallback.target.call(abi.encodeWithSelector(lastCallback.selector, requestId, a, signature));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev Status 1 (refused) or 2 (no result), through the failure hook, with the stipend.
    function fail(bytes32 requestId, uint8 status, bytes32 reason) external returns (bool ok) {
        require(lastFailureSelector != bytes4(0), "no failure hook");
        (ok,) = lastCallback.target.call{gas: CALLBACK_GAS}(
            abi.encodeWithSelector(lastFailureSelector, requestId, status, reason, uint16(0), uint16(0), bytes(""))
        );
        delivered = ok;
    }
}
