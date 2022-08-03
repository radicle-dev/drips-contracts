// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {DSTest} from "ds-test/test.sol";
import {AddressAppUser} from "./AddressAppUser.t.sol";
import {Hevm} from "./Hevm.t.sol";
import {SplitsReceiver, DripsConfigImpl, DripsHub, DripsReceiver} from "../DripsHub.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract DripsHubUserUtils is DSTest {
    DripsHub internal dripsHub;
    IERC20 internal defaultErc20;

    // Keys are user ID and ERC-20
    mapping(uint256 => mapping(IERC20 => DripsReceiver[])) internal drips;
    // Keys is user ID
    mapping(uint256 => SplitsReceiver[]) internal currSplitsReceivers;

    function warpToCycleEnd() internal {
        warpBy(dripsHub.cycleSecs() - (block.timestamp % dripsHub.cycleSecs()));
    }

    function warpBy(uint256 secs) internal {
        Hevm(HEVM_ADDRESS).warp(block.timestamp + secs);
    }

    function calcUserId(uint32 appId, uint224 userIdPart) internal view returns (uint256) {
        return (uint256(appId) << dripsHub.APP_ID_OFFSET()) | userIdPart;
    }

    function loadDrips(AddressAppUser user)
        internal
        returns (DripsReceiver[] memory currReceivers)
    {
        return loadDrips(defaultErc20, user);
    }

    function loadDrips(IERC20 erc20, AddressAppUser user)
        internal
        returns (DripsReceiver[] memory currReceivers)
    {
        currReceivers = drips[user.userId()][erc20];
        assertDrips(erc20, user, currReceivers);
    }

    function storeDrips(AddressAppUser user, DripsReceiver[] memory newReceivers) internal {
        storeDrips(defaultErc20, user, newReceivers);
    }

    function storeDrips(
        IERC20 erc20,
        AddressAppUser user,
        DripsReceiver[] memory newReceivers
    ) internal {
        assertDrips(erc20, user, newReceivers);
        delete drips[user.userId()][erc20];
        for (uint256 i = 0; i < newReceivers.length; i++) {
            drips[user.userId()][erc20].push(newReceivers[i]);
        }
    }

    function getCurrSplitsReceivers(AddressAppUser user)
        internal
        returns (SplitsReceiver[] memory currSplits)
    {
        currSplits = currSplitsReceivers[user.userId()];
        assertSplits(user, currSplits);
    }

    function setCurrSplitsReceivers(AddressAppUser user, SplitsReceiver[] memory newReceivers)
        internal
    {
        assertSplits(user, newReceivers);
        delete currSplitsReceivers[user.userId()];
        for (uint256 i = 0; i < newReceivers.length; i++) {
            currSplitsReceivers[user.userId()].push(newReceivers[i]);
        }
    }

    function dripsReceivers() internal pure returns (DripsReceiver[] memory list) {
        list = new DripsReceiver[](0);
    }

    function dripsReceivers(AddressAppUser user, uint128 amtPerSec)
        internal
        view
        returns (DripsReceiver[] memory list)
    {
        list = new DripsReceiver[](1);
        list[0] = DripsReceiver(
            user.userId(),
            DripsConfigImpl.create(uint192(amtPerSec * dripsHub.AMT_PER_SEC_MULTIPLIER()), 0, 0)
        );
    }

    function dripsReceivers(
        AddressAppUser user1,
        uint128 amtPerSec1,
        AddressAppUser user2,
        uint128 amtPerSec2
    ) internal view returns (DripsReceiver[] memory list) {
        list = new DripsReceiver[](2);
        list[0] = DripsReceiver(
            user1.userId(),
            DripsConfigImpl.create(uint192(amtPerSec1 * dripsHub.AMT_PER_SEC_MULTIPLIER()), 0, 0)
        );
        list[1] = DripsReceiver(
            user2.userId(),
            DripsConfigImpl.create(uint192(amtPerSec2 * dripsHub.AMT_PER_SEC_MULTIPLIER()), 0, 0)
        );
    }

    function setDrips(
        AddressAppUser user,
        uint128 balanceFrom,
        uint128 balanceTo,
        DripsReceiver[] memory newReceivers
    ) internal {
        setDrips(defaultErc20, user, balanceFrom, balanceTo, newReceivers);
    }

    function setDrips(
        IERC20 erc20,
        AddressAppUser user,
        uint128 balanceFrom,
        uint128 balanceTo,
        DripsReceiver[] memory newReceivers
    ) internal {
        int128 balanceDelta = int128(balanceTo) - int128(balanceFrom);
        uint256 expectedBalance = uint256(int256(erc20.balanceOf(address(user))) - balanceDelta);
        DripsReceiver[] memory currReceivers = loadDrips(erc20, user);

        (uint128 newBalance, int128 realBalanceDelta) = user.setDrips(
            erc20,
            currReceivers,
            balanceDelta,
            newReceivers
        );

        storeDrips(erc20, user, newReceivers);
        assertEq(newBalance, balanceTo, "Invalid drips balance");
        assertEq(realBalanceDelta, balanceDelta, "Invalid real balance delta");
        (, uint32 updateTime, uint128 actualBalance, ) = dripsHub.dripsState(user.userId(), erc20);
        assertEq(updateTime, block.timestamp, "Invalid new last update time");
        assertEq(balanceTo, actualBalance, "Invalid drips balance");
        assertEq(balanceTo, actualBalance, "Invalid drips balance");
        assertBalance(erc20, user, expectedBalance);
    }

    function assertDrips(
        IERC20 erc20,
        AddressAppUser user,
        DripsReceiver[] memory currReceivers
    ) internal {
        (bytes32 actual, , , ) = dripsHub.dripsState(user.userId(), erc20);
        bytes32 expected = dripsHub.hashDrips(currReceivers);
        assertEq(actual, expected, "Invalid drips configuration");
    }

    function assertDripsBalance(AddressAppUser user, uint128 expected) internal {
        uint128 balance = dripsHub.balanceAt(
            user.userId(),
            defaultErc20,
            loadDrips(user),
            uint32(block.timestamp)
        );
        assertEq(balance, expected, "Invaild drips balance");
    }

    function changeBalance(
        AddressAppUser user,
        uint128 balanceFrom,
        uint128 balanceTo
    ) internal {
        setDrips(user, balanceFrom, balanceTo, loadDrips(user));
    }

    function assertSetReceiversReverts(
        AddressAppUser user,
        DripsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        assertSetDripsReverts(user, loadDrips(user), 0, newReceivers, expectedReason);
    }

    function assertSetDripsReverts(
        AddressAppUser user,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        try user.setDrips(defaultErc20, currReceivers, balanceDelta, newReceivers) {
            assertTrue(false, "Set drips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid set drips revert reason");
        }
    }

    function give(
        AddressAppUser user,
        AddressAppUser receiver,
        uint128 amt
    ) internal {
        give(defaultErc20, user, receiver, amt);
    }

    function give(
        IERC20 erc20,
        AddressAppUser user,
        AddressAppUser receiver,
        uint128 amt
    ) internal {
        uint256 expectedBalance = uint256(erc20.balanceOf(address(user)) - amt);
        uint128 expectedCollectable = totalCollectableAll(erc20, receiver) + amt;

        user.give(receiver.userId(), erc20, amt);

        assertBalance(erc20, user, expectedBalance);
        assertTotalCollectableAll(erc20, receiver, expectedCollectable);
    }

    function splitsReceivers() internal pure returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](0);
    }

    function splitsReceivers(AddressAppUser user, uint32 weight)
        internal
        view
        returns (SplitsReceiver[] memory list)
    {
        list = new SplitsReceiver[](1);
        list[0] = SplitsReceiver(user.userId(), weight);
    }

    function splitsReceivers(
        AddressAppUser user1,
        uint32 weight1,
        AddressAppUser user2,
        uint32 weight2
    ) internal view returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](2);
        list[0] = SplitsReceiver(user1.userId(), weight1);
        list[1] = SplitsReceiver(user2.userId(), weight2);
    }

    function setSplits(AddressAppUser user, SplitsReceiver[] memory newReceivers) internal {
        SplitsReceiver[] memory curr = getCurrSplitsReceivers(user);
        assertSplits(user, curr);

        user.setSplits(newReceivers);

        setCurrSplitsReceivers(user, newReceivers);
        assertSplits(user, newReceivers);
    }

    function assertSetSplitsReverts(
        AddressAppUser user,
        SplitsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        SplitsReceiver[] memory curr = getCurrSplitsReceivers(user);
        assertSplits(user, curr);
        try user.setSplits(newReceivers) {
            assertTrue(false, "setSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid setSplits revert reason");
        }
    }

    function assertSplits(AddressAppUser user, SplitsReceiver[] memory expectedReceivers) internal {
        bytes32 actual = dripsHub.splitsHash(user.userId());
        bytes32 expected = dripsHub.hashSplits(expectedReceivers);
        assertEq(actual, expected, "Invalid splits hash");
    }

    function collectAll(AddressAppUser user, uint128 expectedAmt) internal {
        collectAll(defaultErc20, user, expectedAmt, 0);
    }

    function collectAll(
        IERC20 erc20,
        AddressAppUser user,
        uint128 expectedAmt
    ) internal {
        collectAll(erc20, user, expectedAmt, 0);
    }

    function collectAll(
        AddressAppUser user,
        uint128 expectedCollected,
        uint128 expectedSplit
    ) internal {
        collectAll(defaultErc20, user, expectedCollected, expectedSplit);
    }

    function collectAll(
        IERC20 erc20,
        AddressAppUser user,
        uint128 expectedCollected,
        uint128 expectedSplit
    ) internal {
        assertCollectableAll(erc20, user, expectedCollected, expectedSplit);
        uint256 expectedBalance = erc20.balanceOf(address(user)) + expectedCollected;

        (uint128 collectedAmt, uint128 splitAmt) = user.collectAll(
            address(user),
            erc20,
            getCurrSplitsReceivers(user)
        );

        assertEq(collectedAmt, expectedCollected, "Invalid collected amount");
        assertEq(splitAmt, expectedSplit, "Invalid split amount");
        assertCollectableAll(erc20, user, 0);
        assertBalance(erc20, user, expectedBalance);
    }

    function assertCollectableAll(AddressAppUser user, uint128 expected) internal {
        assertCollectableAll(defaultErc20, user, expected, 0);
    }

    function assertCollectableAll(
        IERC20 erc20,
        AddressAppUser user,
        uint128 expected
    ) internal {
        assertCollectableAll(erc20, user, expected, 0);
    }

    function assertCollectableAll(
        AddressAppUser user,
        uint128 expectedCollected,
        uint128 expectedSplit
    ) internal {
        assertCollectableAll(defaultErc20, user, expectedCollected, expectedSplit);
    }

    function assertCollectableAll(
        IERC20 erc20,
        AddressAppUser user,
        uint128 expectedCollected,
        uint128 expectedSplit
    ) internal {
        (uint128 actualCollected, uint128 actualSplit) = dripsHub.collectableAll(
            user.userId(),
            erc20,
            getCurrSplitsReceivers(user)
        );
        assertEq(actualCollected, expectedCollected, "Invalid collected");
        assertEq(actualSplit, expectedSplit, "Invalid split");
    }

    function totalCollectableAll(IERC20 erc20, AddressAppUser user) internal returns (uint128) {
        SplitsReceiver[] memory splits = getCurrSplitsReceivers(user);
        (uint128 collectableAmt, uint128 splittableAmt) = dripsHub.collectableAll(
            user.userId(),
            erc20,
            splits
        );
        return collectableAmt + splittableAmt;
    }

    function assertTotalCollectableAll(
        IERC20 erc20,
        AddressAppUser user,
        uint128 expectedCollectable
    ) internal {
        uint128 actualCollectable = totalCollectableAll(erc20, user);
        assertEq(actualCollectable, expectedCollectable, "Invalid total collectable");
    }

    function receiveDrips(
        AddressAppUser user,
        uint128 expectedReceivedAmt,
        uint32 expectedReceivedCycles
    ) internal {
        receiveDrips(user, type(uint32).max, expectedReceivedAmt, expectedReceivedCycles, 0, 0);
    }

    function receiveDrips(
        AddressAppUser user,
        uint32 maxCycles,
        uint128 expectedReceivedAmt,
        uint32 expectedReceivedCycles,
        uint128 expectedAmtAfter,
        uint32 expectedCyclesAfter
    ) internal {
        uint128 expectedTotalAmt = expectedReceivedAmt + expectedAmtAfter;
        uint32 expectedTotalCycles = expectedReceivedCycles + expectedCyclesAfter;
        assertReceivableDripsCycles(user, expectedTotalCycles);
        assertReceivableDrips(user, type(uint32).max, expectedTotalAmt, 0);
        assertReceivableDrips(user, maxCycles, expectedReceivedAmt, expectedCyclesAfter);

        (uint128 receivedAmt, uint32 receivableCycles) = dripsHub.receiveDrips(
            user.userId(),
            defaultErc20,
            maxCycles
        );

        assertEq(receivedAmt, expectedReceivedAmt, "Invalid amount received from drips");
        assertEq(receivableCycles, expectedCyclesAfter, "Invalid receivable drips cycles left");
        assertReceivableDripsCycles(user, expectedCyclesAfter);
        assertReceivableDrips(user, type(uint32).max, expectedAmtAfter, 0);
    }

    function assertReceivableDripsCycles(AddressAppUser user, uint32 expectedCycles) internal {
        uint32 actualCycles = dripsHub.receivableDripsCycles(user.userId(), defaultErc20);
        assertEq(actualCycles, expectedCycles, "Invalid total receivable drips cycles");
    }

    function assertReceivableDrips(
        AddressAppUser user,
        uint32 maxCycles,
        uint128 expectedAmt,
        uint32 expectedCycles
    ) internal {
        (uint128 actualAmt, uint32 actualCycles) = dripsHub.receivableDrips(
            user.userId(),
            defaultErc20,
            maxCycles
        );
        assertEq(actualAmt, expectedAmt, "Invalid receivable amount");
        assertEq(actualCycles, expectedCycles, "Invalid receivable drips cycles");
    }

    function split(
        AddressAppUser user,
        uint128 expectedCollectable,
        uint128 expectedSplit
    ) internal {
        assertSplittable(user, expectedCollectable + expectedSplit);
        uint128 collectableBefore = collectable(user);

        (uint128 collectableAmt, uint128 splitAmt) = dripsHub.split(
            user.userId(),
            defaultErc20,
            getCurrSplitsReceivers(user)
        );

        assertEq(collectableAmt, expectedCollectable, "Invalid collectable amount");
        assertEq(splitAmt, expectedSplit, "Invalid split amount");
        assertSplittable(user, 0);
        assertCollectable(user, collectableBefore + expectedCollectable);
    }

    function assertSplittable(AddressAppUser user, uint256 expected) internal {
        uint256 actual = dripsHub.splittable(user.userId(), defaultErc20);
        assertEq(actual, expected, "Invalid splittable");
    }

    function collect(AddressAppUser user, uint128 expectedAmt) internal {
        assertCollectable(user, expectedAmt);
        uint256 balanceBefore = defaultErc20.balanceOf(address(user));

        uint128 actualAmt = user.collect(address(user), defaultErc20);

        assertEq(actualAmt, expectedAmt, "Invalid collected amount");
        assertCollectable(user, 0);
        assertBalance(user, balanceBefore + expectedAmt);
    }

    function collectable(AddressAppUser user) internal view returns (uint128 amt) {
        return dripsHub.collectable(user.userId(), defaultErc20);
    }

    function assertCollectable(AddressAppUser user, uint256 expected) internal {
        assertEq(collectable(user), expected, "Invalid collectable");
    }

    function assertBalance(AddressAppUser user, uint256 expected) internal {
        assertBalance(defaultErc20, user, expected);
    }

    function assertBalance(
        IERC20 erc20,
        AddressAppUser user,
        uint256 expected
    ) internal {
        assertEq(erc20.balanceOf(address(user)), expected, "Invalid balance");
    }
}
