// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StorageSlot} from "openzeppelin-contracts/utils/StorageSlot.sol";

/// @notice A mix-in for contract UUPS-upgradability, pausability and admin management.
/// It can't be used directly, only via a proxy. It uses the upgrade-safe ERC-1967 storage scheme.
///
/// Managed uses the ERC-1967 admin slot to store the admin address.
/// All instances of the contracts are owned by address `0x00`.
/// While this contract is capable of updating the admin,
/// the proxy is expected to set up the initial value of the ERC-1967 admin.
///
/// All instances of the contracts are paused and can't be unpaused.
/// When a proxy uses such contract via delegation, it's initially unpaused.
abstract contract Managed is UUPSUpgradeable {
    /// @notice The pointer to the storage slot with the boolean holding the paused state.
    bytes32 private immutable pausedSlot = erc1967Slot("eip1967.managed.paused");

    /// @notice Emitted when the pause is triggered.
    /// @param caller The caller who triggered the change.
    event Paused(address caller);

    /// @notice Emitted when the pause is lifted.
    /// @param caller The caller who triggered the change.
    event Unpaused(address caller);

    /// @notice Initializes the contract in paused state and with no admin.
    /// The contract instance can be used only as a call delegation target for a proxy.
    constructor() {
        StorageSlot.getBooleanSlot(pausedSlot).value = true;
    }

    /// @notice Throws if called by any caller other than the admin.
    modifier onlyAdmin() {
        require(admin() == msg.sender, "Caller is not the admin");
        _;
    }

    /// @notice Calculates the ERC-1967 slot pointer.
    /// @param name The name of the slot, should be globally unique
    /// @return slot The slot pointer
    function erc1967Slot(string memory name) internal pure returns (bytes32 slot) {
        return bytes32(uint256(keccak256(bytes(name))) - 1);
    }

    /// @notice Authorizes the contract upgrade. See `UUPSUpgradable` docs for more details.
    function _authorizeUpgrade(address newImplementation) internal view override onlyAdmin {
        newImplementation;
    }

    /// @notice Returns the address of the current admin.
    function admin() public view returns (address) {
        return _getAdmin();
    }

    /// @notice Changes the admin of the contract.
    /// Can only be called by the current admin.
    function changeAdmin(address newAdmin) public onlyAdmin {
        _changeAdmin(newAdmin);
    }

    /// @notice Returns true if the contract is paused, and false otherwise.
    function paused() public view returns (bool isPaused) {
        return _pausedSlot().value;
    }

    /// @notice Triggers stopped state.
    function pause() public onlyAdmin whenNotPaused {
        _pausedSlot().value = true;
        emit Paused(msg.sender);
    }

    /// @notice Returns to normal state.
    function unpause() public onlyAdmin whenPaused {
        _pausedSlot().value = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Modifier to make a function callable only when the contract is not paused.
    modifier whenNotPaused() {
        require(!paused(), "Contract paused");
        _;
    }

    /// @notice Modifier to make a function callable only when the contract is paused.
    modifier whenPaused() {
        require(paused(), "Contract not paused");
        _;
    }

    function _pausedSlot() private view returns (StorageSlot.BooleanSlot storage slot) {
        return StorageSlot.getBooleanSlot(pausedSlot);
    }
}

/// @notice A generic proxy for Managed.
contract Proxy is ERC1967Proxy {
    constructor(Managed logic, address admin) ERC1967Proxy(address(logic), new bytes(0)) {
        _changeAdmin(admin);
    }
}
