// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

/// @notice A splits receiver
struct SplitsReceiver {
    /// @notice The user ID.
    uint256 userId;
    /// @notice The splits weight. Must never be zero.
    /// The user will be getting `weight / _TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the splitting user.
    uint32 weight;
}

abstract contract Splits {
    /// @notice Maximum number of splits receivers of a single user.
    /// Limits cost of collecting.
    uint32 internal constant _MAX_SPLITS_RECEIVERS = 200;
    /// @notice The total splits weight of a user
    uint32 internal constant _TOTAL_SPLITS_WEIGHT = 1_000_000;
    /// @notice The storage slot holding a single `SplitsStorage` structure.
    bytes32 private immutable _splitsStorageSlot;

    /// @notice Emitted when a user collects funds
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param collected The collected amount
    event Collected(uint256 indexed userId, uint256 indexed assetId, uint128 collected);

    /// @notice Emitted when funds are split from a user to a receiver.
    /// This is caused by the user collecting received funds.
    /// @param userId The user ID
    /// @param receiver The splits receiver user ID
    /// @param assetId The used asset ID
    /// @param amt The amount split to the receiver
    event Split(
        uint256 indexed userId,
        uint256 indexed receiver,
        uint256 indexed assetId,
        uint128 amt
    );

    /// @notice Emitted when funds are made collectable after splitting.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param amt The amount made collectable for the user on top of what was collectable before.
    event Collectable(uint256 indexed userId, uint256 indexed assetId, uint128 amt);

    /// @notice Emitted when funds are given from the user to the receiver.
    /// @param userId The user ID
    /// @param receiver The receiver user ID
    /// @param assetId The used asset ID
    /// @param amt The given amount
    event Given(
        uint256 indexed userId,
        uint256 indexed receiver,
        uint256 indexed assetId,
        uint128 amt
    );

    /// @notice Emitted when the user's splits are updated.
    /// @param userId The user ID
    /// @param receiversHash The splits receivers list hash
    event SplitsSet(uint256 indexed userId, bytes32 indexed receiversHash);

    /// @notice Emitted when a user is seen in a splits receivers list.
    /// @param receiversHash The splits receivers list hash
    /// @param userId The user ID.
    /// @param weight The splits weight. Must never be zero.
    /// The user will be getting `weight / _TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the splitting user.
    event SplitsReceiverSeen(bytes32 indexed receiversHash, uint256 indexed userId, uint32 weight);

    struct SplitsStorage {
        /// @notice User splits states.
        /// The key is the user ID.
        mapping(uint256 => SplitsState) splitsStates;
    }

    struct SplitsState {
        /// @notice The user's splits configuration hash, see `hashSplits`.
        bytes32 splitsHash;
        /// @notice The user's splits balance. The key is the asset ID.
        mapping(uint256 => SplitsBalance) balances;
    }

    struct SplitsBalance {
        /// @notice The not yet split balance, must be split before collecting by the user.
        uint128 splittable;
        /// @notice The already split balance, ready to be collected by the user.
        uint128 collectable;
    }

    /// @param splitsStorageSlot The storage slot to holding a single `SplitsStorage` structure.
    constructor(bytes32 splitsStorageSlot) {
        _splitsStorageSlot = splitsStorageSlot;
    }

    /// @notice Returns user's received but not split yet funds.
    /// @param userId The user ID
    /// @param assetId The used asset ID.
    /// @return amt The amount received but not split yet.
    function _splittable(uint256 userId, uint256 assetId) internal view returns (uint128 amt) {
        return _splitsStorage().splitsStates[userId].balances[assetId].splittable;
    }

    /// @notice Calculate results of splitting an amount using the current splits configuration.
    /// @param userId The user ID
    /// @param currReceivers The list of the user's current splits receivers.
    /// @param amount The amount being split.
    /// @return collectableAmt The amount made collectable for the user
    /// on top of what was collectable before.
    /// @return splitAmt The amount split to the user's splits receivers
    function _splitResults(
        uint256 userId,
        SplitsReceiver[] memory currReceivers,
        uint128 amount
    ) internal view returns (uint128 collectableAmt, uint128 splitAmt) {
        _assertCurrSplits(userId, currReceivers);
        if (amount == 0) return (0, 0);
        uint32 splitsWeight = 0;
        for (uint256 i = 0; i < currReceivers.length; i++) {
            splitsWeight += currReceivers[i].weight;
        }
        splitAmt = uint128((uint160(amount) * splitsWeight) / _TOTAL_SPLITS_WEIGHT);
        collectableAmt = amount - splitAmt;
    }

    /// @notice Splits user's received but not split yet funds among receivers.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param currReceivers The list of the user's current splits receivers.
    /// @return collectableAmt The amount made collectable for the user
    /// on top of what was collectable before.
    /// @return splitAmt The amount split to the user's splits receivers
    function _split(
        uint256 userId,
        uint256 assetId,
        SplitsReceiver[] memory currReceivers
    ) internal returns (uint128 collectableAmt, uint128 splitAmt) {
        _assertCurrSplits(userId, currReceivers);
        mapping(uint256 => SplitsState) storage splitsStates = _splitsStorage().splitsStates;
        SplitsBalance storage balance = splitsStates[userId].balances[assetId];

        collectableAmt = balance.splittable;
        if (collectableAmt == 0) return (0, 0);

        balance.splittable = 0;
        uint32 splitsWeight = 0;
        for (uint256 i = 0; i < currReceivers.length; i++) {
            splitsWeight += currReceivers[i].weight;
            uint128 currSplitAmt = uint128(
                (uint160(collectableAmt) * splitsWeight) / _TOTAL_SPLITS_WEIGHT - splitAmt
            );
            splitAmt += currSplitAmt;
            uint256 receiver = currReceivers[i].userId;
            splitsStates[receiver].balances[assetId].splittable += currSplitAmt;
            emit Split(userId, receiver, assetId, currSplitAmt);
        }
        collectableAmt -= splitAmt;
        balance.collectable += collectableAmt;
        emit Collectable(userId, assetId, collectableAmt);
    }

    /// @notice Returns user's received funds already split and ready to be collected.
    /// @param userId The user ID
    /// @param assetId The used asset ID.
    /// @return amt The collectable amount.
    function _collectable(uint256 userId, uint256 assetId) internal view returns (uint128 amt) {
        return _splitsStorage().splitsStates[userId].balances[assetId].collectable;
    }

    /// @notice Collects user's received already split funds
    /// and transfers them out of the drips hub contract to msg.sender.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return amt The collected amount
    function _collect(uint256 userId, uint256 assetId) internal returns (uint128 amt) {
        SplitsBalance storage balance = _splitsStorage().splitsStates[userId].balances[assetId];
        amt = balance.collectable;
        balance.collectable = 0;
        emit Collected(userId, assetId, amt);
    }

    /// @notice Gives funds from the user to the receiver.
    /// The receiver can split and collect them immediately.
    /// Transfers the funds to be given from the user's wallet to the drips hub contract.
    /// @param userId The user ID
    /// @param receiver The receiver
    /// @param assetId The used asset ID
    /// @param amt The given amount
    function _give(
        uint256 userId,
        uint256 receiver,
        uint256 assetId,
        uint128 amt
    ) internal {
        _splitsStorage().splitsStates[receiver].balances[assetId].splittable += amt;
        emit Given(userId, receiver, assetId, amt);
    }

    /// @notice Sets user splits configuration.
    /// @param userId The user ID
    /// @param receivers The list of the user's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / _TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the user.
    function _setSplits(uint256 userId, SplitsReceiver[] memory receivers) internal {
        SplitsState storage state = _splitsStorage().splitsStates[userId];
        bytes32 newSplitsHash = _hashSplits(receivers);
        emit SplitsSet(userId, newSplitsHash);
        if (newSplitsHash != state.splitsHash) {
            _assertSplitsValid(receivers, newSplitsHash);
            state.splitsHash = newSplitsHash;
        }
    }

    /// @notice Validates a list of splits receivers and emits events for them
    /// @param receivers The list of splits receivers
    /// @param receiversHash The hash of the list of splits receivers.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    function _assertSplitsValid(SplitsReceiver[] memory receivers, bytes32 receiversHash) private {
        require(receivers.length <= _MAX_SPLITS_RECEIVERS, "Too many splits receivers");
        uint64 totalWeight = 0;
        uint256 prevUserId;
        for (uint256 i = 0; i < receivers.length; i++) {
            SplitsReceiver memory receiver = receivers[i];
            uint32 weight = receiver.weight;
            require(weight != 0, "Splits receiver weight is zero");
            totalWeight += weight;
            uint256 userId = receiver.userId;
            if (i > 0) {
                require(prevUserId != userId, "Duplicate splits receivers");
                require(prevUserId < userId, "Splits receivers not sorted by user ID");
            }
            prevUserId = userId;
            emit SplitsReceiverSeen(receiversHash, userId, weight);
        }
        require(totalWeight <= _TOTAL_SPLITS_WEIGHT, "Splits weights sum too high");
    }

    /// @notice Asserts that the list of splits receivers is the user's currently used one.
    /// @param userId The user ID
    /// @param currReceivers The list of the user's current splits receivers.
    function _assertCurrSplits(uint256 userId, SplitsReceiver[] memory currReceivers)
        internal
        view
    {
        require(
            _hashSplits(currReceivers) == _splitsHash(userId),
            "Invalid current splits receivers"
        );
    }

    /// @notice Current user's splits hash, see `hashSplits`.
    /// @param userId The user ID
    /// @return currSplitsHash The current user's splits hash
    function _splitsHash(uint256 userId) internal view returns (bytes32 currSplitsHash) {
        return _splitsStorage().splitsStates[userId].splitsHash;
    }

    /// @notice Calculates the hash of the list of splits receivers.
    /// @param receivers The list of the splits receivers.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// @return receiversHash The hash of the list of splits receivers.
    function _hashSplits(SplitsReceiver[] memory receivers)
        internal
        pure
        returns (bytes32 receiversHash)
    {
        if (receivers.length == 0) return bytes32(0);
        return keccak256(abi.encode(receivers));
    }

    /// @notice Returns the Splits storage.
    /// @return splitsStorage The storage.
    function _splitsStorage() private view returns (SplitsStorage storage splitsStorage) {
        bytes32 slot = _splitsStorageSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            splitsStorage.slot := slot
        }
    }
}
