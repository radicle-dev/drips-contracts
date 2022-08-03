// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {DSTest} from "ds-test/test.sol";
import {Splits, SplitsReceiver} from "../Splits.sol";

contract SplitsTest is DSTest, Splits {
    Splits.SplitsStorage internal s;
    // Keys is user ID
    mapping(uint256 => SplitsReceiver[]) internal currSplitsReceivers;

    uint256 internal defaultAsset = 1;
    uint256 internal otherAsset = 2;
    uint256 internal receiver = 4;
    uint256 internal receiver1 = 5;
    uint256 internal receiver2 = 6;
    uint256 internal receiver3 = 7;
    uint256 internal user = 9;

    constructor() Splits(bytes32(uint256(1000))) {
        return;
    }

    function splitsReceivers() internal pure returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](0);
    }

    function splitsReceivers(uint256 userId, uint32 weight)
        internal
        pure
        returns (SplitsReceiver[] memory list)
    {
        list = new SplitsReceiver[](1);
        list[0] = SplitsReceiver(userId, weight);
    }

    function splitsReceivers(
        uint256 user1,
        uint32 weight1,
        uint256 user2,
        uint32 weight2
    ) internal pure returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](2);
        list[0] = SplitsReceiver(user1, weight1);
        list[1] = SplitsReceiver(user2, weight2);
    }

    function getCurrSplitsReceivers(uint256 userId)
        internal
        view
        returns (SplitsReceiver[] memory currSplits)
    {
        currSplits = currSplitsReceivers[userId];

        Splits._assertCurrSplits(userId, currSplits);
    }

    function setSplitsExternal(uint256 userId, SplitsReceiver[] memory newReceivers) external {
        Splits._setSplits(userId, newReceivers);
    }

    function assertSetSplitsReverts(
        uint256 userId,
        SplitsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        SplitsReceiver[] memory curr = getCurrSplitsReceivers(userId);
        Splits._assertCurrSplits(userId, curr);
        try this.setSplitsExternal(userId, newReceivers) {
            assertTrue(false, "setSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid setSplits revert reason");
        }
    }

    function assertSplits(uint256 userId, SplitsReceiver[] memory expectedReceivers) internal view {
        Splits._assertCurrSplits(userId, expectedReceivers);
    }

    function assertSplittable(uint256 userId, uint256 expected) internal {
        uint256 actual = Splits._splittable(userId, defaultAsset);
        assertEq(actual, expected, "Invalid splittable");
    }

    function setSplits(uint256 userId, SplitsReceiver[] memory newReceivers) internal {
        SplitsReceiver[] memory curr = getCurrSplitsReceivers(userId);
        assertSplits(userId, curr);

        Splits._setSplits(userId, newReceivers);

        setCurrSplitsReceivers(userId, newReceivers);
    }

    function setCurrSplitsReceivers(uint256 userId, SplitsReceiver[] memory newReceivers) internal {
        assertSplits(userId, newReceivers);
        delete currSplitsReceivers[userId];
        for (uint256 i = 0; i < newReceivers.length; i++) {
            currSplitsReceivers[userId].push(newReceivers[i]);
        }
    }

    function splitExternal(
        uint256 userId,
        uint256 assetId,
        SplitsReceiver[] memory currReceivers
    ) external {
        Splits._split(userId, assetId, currReceivers);
    }

    function split(
        uint256 asset,
        uint256 userId,
        uint128 expectedCollectable,
        uint128 expectedSplit
    ) internal {
        (uint128 collectableAmt, uint128 splitAmt) = Splits._split(
            userId,
            asset,
            getCurrSplitsReceivers(userId)
        );

        assertEq(collectableAmt, expectedCollectable, "Invalid collectable amount");
        assertEq(Splits._collectable(userId, asset), collectableAmt);
        assertEq(splitAmt, expectedSplit, "Invalid split amount");
        assertSplittable(userId, 0);
    }

    function split(
        uint256 userId,
        uint128 expectedCollectable,
        uint128 expectedSplit
    ) internal {
        split(defaultAsset, userId, expectedCollectable, expectedSplit);
    }

    function give(
        uint256 sender,
        uint256 splitReceiver,
        uint128 amt
    ) public {
        Splits._give(sender, splitReceiver, defaultAsset, amt);
        assertSplittable(splitReceiver, amt);
    }

    function collect(uint256 userId, uint128 expectedAmt) public returns (uint128 collected) {
        assertEq(Splits._collectable(userId, defaultAsset), expectedAmt);
        return Splits._collect(userId, defaultAsset);
    }

    function splitCollect(
        uint256 asset,
        uint256 userId,
        uint128 expectedCollectable,
        uint128 expectedSplit
    ) public returns (uint128 collectedAmt) {
        split(asset, userId, expectedCollectable, expectedSplit);
        return Splits._collect(userId, asset);
    }

    function splitCollect(
        uint256 userId,
        uint128 expectedCollectable,
        uint128 expectedSplit
    ) public returns (uint128 collectedAmt) {
        return splitCollect(defaultAsset, userId, expectedCollectable, expectedSplit);
    }

    // test cases
    function testSplitable() public {
        uint128 amt = 10;
        Splits._give(0, user, defaultAsset, amt);
        assertSplittable(user, amt);
    }

    function testSimpleSplit() public {
        // 60% split
        setSplits(user, splitsReceivers(receiver, (Splits._TOTAL_SPLITS_WEIGHT / 10) * 6));
        uint128 amt = 10;
        Splits._give(0, user, defaultAsset, amt);
        assertSplittable(user, amt);

        uint128 expectedCollectable = 4;
        uint128 expectedSplit = 6;
        split(user, expectedCollectable, expectedSplit);
    }

    function testLimitsTheTotalSplitsReceiversCount() public {
        uint160 countMax = Splits._MAX_SPLITS_RECEIVERS;
        SplitsReceiver[] memory receiversGood = new SplitsReceiver[](countMax);
        SplitsReceiver[] memory receiversBad = new SplitsReceiver[](countMax + 1);
        for (uint160 i = 0; i < countMax; i++) {
            receiversGood[i] = SplitsReceiver(i, 1);
            receiversBad[i] = receiversGood[i];
        }
        receiversBad[countMax] = SplitsReceiver(countMax, 1);

        setSplits(user, receiversGood);
        assertSetSplitsReverts(user, receiversBad, "Too many splits receivers");
    }

    function testRejectsTooHighTotalWeightSplitsReceivers() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        setSplits(user, splitsReceivers(receiver, totalWeight));
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, totalWeight + 1),
            "Splits weights sum too high"
        );
    }

    function testRejectsZeroWeightSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, 0),
            "Splits receiver weight is zero"
        );
    }

    function testRejectsUnsortedSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver2, 1, receiver1, 1),
            "Splits receivers not sorted by user ID"
        );
    }

    function testRejectsDuplicateSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, 1, receiver, 2),
            "Duplicate splits receivers"
        );
    }

    function testCanSplitAllWhenCollectedDoesntSplitEvenly() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        // 3 waiting for receiver 1
        Splits._give(user, receiver1, defaultAsset, 3);

        setSplits(
            receiver1,
            splitsReceivers(receiver2, totalWeight / 2, receiver3, totalWeight / 2)
        );

        // Receiver1 received 3 which 100% is split
        split(receiver1, 0, 3);
        // Receiver2 got 1 split from receiver
        split(receiver2, 1, 0);
        // Receiver3 got 2 split from receiver
        split(receiver3, 2, 0);
    }

    function testSplitRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try this.splitExternal(user, defaultAsset, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Split hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid current splits receivers", "Invalid split revert reason");
        }
    }

    function testSplittingSplitsAllFundsEvenWhenTheyDontDivideEvenly() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        setSplits(
            user,
            splitsReceivers(receiver1, (totalWeight / 5) * 2, receiver2, totalWeight / 5)
        );
        Splits._give(0, user, defaultAsset, 9);
        // user gets 40% of 9, receiver1 40 % and receiver2 20%
        split(user, 4, 5);
        split(receiver1, 3, 0);
        split(receiver2, 2, 0);
    }

    function testUserCanSplitToThemselves() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        // receiver1 receives 30%, gets 50% split to themselves and receiver2 gets split 20%
        setSplits(
            receiver1,
            splitsReceivers(receiver1, totalWeight / 2, receiver2, totalWeight / 5)
        );
        give(receiver1, receiver1, 20);

        (uint128 collectableAmt, uint128 splitAmt) = Splits._split(
            receiver1,
            defaultAsset,
            getCurrSplitsReceivers(receiver1)
        );

        assertEq(collectableAmt, 6, "Invalid collectable amount");
        assertEq(splitAmt, 14, "Invalid split amount");

        assertSplittable(receiver1, 10);
        collect(receiver1, 6);
        splitCollect(receiver2, 4, 0);

        // // Splitting 10 which has been split to receiver1 themselves in the previous step
        (collectableAmt, splitAmt) = Splits._split(
            receiver1,
            defaultAsset,
            getCurrSplitsReceivers(receiver1)
        );

        assertEq(collectableAmt, 3, "Invalid collectable amount");
        assertEq(splitAmt, 7, "Invalid split amount");
        assertSplittable(receiver1, 5);
        collect(receiver1, 3);
        split(receiver2, 2, 0);
    }

    function testSplitsConfigurationIsCommonBetweenTokens() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        setSplits(user, splitsReceivers(receiver1, totalWeight / 10));
        Splits._give(receiver2, user, defaultAsset, 30);
        Splits._give(receiver2, user, otherAsset, 100);

        splitCollect(defaultAsset, user, 27, 3);
        splitCollect(otherAsset, user, 90, 10);
        splitCollect(defaultAsset, receiver1, 3, 0);
        splitCollect(otherAsset, receiver1, 10, 0);
    }

    function testForwardSplits() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;

        give(user, receiver1, 10);
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        setSplits(receiver2, splitsReceivers(receiver3, totalWeight));

        assertSplittable(receiver2, 0);
        assertSplittable(receiver3, 0);
        // Receiver1 received 10 with a give of which 10 is split
        splitCollect(receiver1, 0, 10);
        // Receiver2 got 10 split from receiver1 of which 10 is split
        splitCollect(receiver2, 0, 10);
        // Receiver3 got 10 split from receiver2
        splitCollect(receiver3, 10, 0);
    }

    function testSplitMultipleReceivers() public {
        uint32 totalWeight = Splits._TOTAL_SPLITS_WEIGHT;
        give(user, receiver1, 10);

        setSplits(
            receiver1,
            splitsReceivers(receiver2, totalWeight / 4, receiver3, totalWeight / 2)
        );
        assertSplittable(receiver2, 0);
        assertSplittable(receiver3, 0);
        // Receiver1 received 10 with a give, of which 3/4 is split, which is 7
        splitCollect(receiver1, 3, 7);
        // Receiver2 got 1/3 of 7 split from receiver1, which is 2
        splitCollect(receiver2, 2, 0);
        // Receiver3 got 2/3 of 7 split from receiver1, which is 5
        splitCollect(receiver3, 5, 0);
    }
}
