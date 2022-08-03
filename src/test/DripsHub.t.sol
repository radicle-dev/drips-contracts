// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {DSTest} from "ds-test/test.sol";
import {DripsHubUserUtils} from "./DripsHubUserUtils.t.sol";
import {AddressAppUser} from "./AddressAppUser.t.sol";
import {ManagedUser} from "./ManagedUser.t.sol";
import {AddressApp} from "../AddressApp.sol";
import {SplitsReceiver, DripsHub, DripsReceiver} from "../DripsHub.sol";
import {Reserve} from "../Reserve.sol";
import {Proxy} from "../Managed.sol";
import {IERC20, ERC20PresetFixedSupply} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract DripsHubTest is DripsHubUserUtils {
    AddressApp private addressApp;

    IERC20 private otherErc20;

    AddressAppUser private user;
    AddressAppUser private receiver;
    AddressAppUser private user1;
    AddressAppUser private receiver1;
    AddressAppUser private user2;
    AddressAppUser private receiver2;
    AddressAppUser private receiver3;
    ManagedUser internal admin;
    ManagedUser internal nonAdmin;

    string internal constant ERROR_NOT_APP = "Callable only by the app";
    string private constant ERROR_NOT_ADMIN = "Caller is not the admin";
    string private constant ERROR_PAUSED = "Contract paused";

    function setUp() public {
        defaultErc20 = new ERC20PresetFixedSupply("test", "test", 10**6 * 1 ether, address(this));
        otherErc20 = new ERC20PresetFixedSupply("other", "other", 10**6 * 1 ether, address(this));
        Reserve reserve = new Reserve(address(this));
        DripsHub hubLogic = new DripsHub(10, reserve);
        dripsHub = DripsHub(address(new Proxy(hubLogic, address(this))));
        reserve.addUser(address(dripsHub));
        addressApp = new AddressApp(dripsHub);
        user = createUser();
        receiver1 = createUser();
        receiver2 = createUser();
        admin = new ManagedUser(dripsHub);
        nonAdmin = new ManagedUser(dripsHub);
        dripsHub.changeAdmin(address(admin));
        user = createUser();
        user1 = createUser();
        user2 = createUser();
        receiver = createUser();
        receiver1 = createUser();
        receiver2 = createUser();
        receiver3 = createUser();
        // Sort receivers by address
        if (receiver1 > receiver2) (receiver1, receiver2) = (receiver2, receiver1);
        if (receiver2 > receiver3) (receiver2, receiver3) = (receiver3, receiver2);
        if (receiver1 > receiver2) (receiver1, receiver2) = (receiver2, receiver1);
    }

    function createUser() internal returns (AddressAppUser newUser) {
        newUser = new AddressAppUser(addressApp);
        defaultErc20.transfer(address(newUser), 100 ether);
        otherErc20.transfer(address(newUser), 100 ether);
    }

    function testDoesNotRequireReceiverToBeInitialized() public {
        collectAll(receiver, 0);
    }

    function testCollectAllRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try user.collectAll(address(user), defaultErc20, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid current splits receivers", "Invalid collect revert reason");
        }
    }

    function testCollectableAllRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try dripsHub.collectableAll(user.userId(), defaultErc20, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Collectable hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(
                reason,
                "Invalid current splits receivers",
                "Invalid collectable revert reason"
            );
        }
    }

    function testCollectAllSplits() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        // Receiver1 had 1 second paying 10 per second of which 10 is split
        collectAll(receiver1, 0, 10);
        // Receiver2 got 10 split from receiver1
        collectAll(receiver2, 10);
    }

    function testUncollectedFundsAreSplitUsingCurrentConfig() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        setSplits(user1, splitsReceivers(receiver1, totalWeight));
        setDrips(user2, 0, 5, dripsReceivers(user1, 5));
        warpToCycleEnd();
        give(user2, user1, 5);
        setSplits(user1, splitsReceivers(receiver2, totalWeight));
        // Receiver1 had 1 second paying 5 per second and was given 5 of which 10 is split
        collectAll(user1, 0, 10);
        // Receiver1 wasn't a splits receiver when user1 was collecting
        assertCollectableAll(receiver1, 0);
        // Receiver2 was a splits receiver when user1 was collecting
        collectAll(receiver2, 10);
    }

    function testCollectAllSplitsFundsFromSplits() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        setSplits(receiver2, splitsReceivers(receiver3, totalWeight));
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        assertCollectableAll(receiver3, 0);
        // Receiver1 had 1 second paying 10 per second of which 10 is split
        collectAll(receiver1, 0, 10);
        // Receiver2 got 10 split from receiver1 of which 10 is split
        collectAll(receiver2, 0, 10);
        // Receiver3 got 10 split from receiver2
        collectAll(receiver3, 10);
    }

    function testCollectAllMixesDripsAndSplits() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 5, receiver2, 5));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        warpToCycleEnd();
        // Receiver2 had 1 second paying 5 per second
        assertCollectableAll(receiver2, 5);
        // Receiver1 had 1 second paying 5 per second
        collectAll(receiver1, 0, 5);
        // Receiver2 had 1 second paying 5 per second and got 5 split from receiver1
        collectAll(receiver2, 10);
    }

    function testCollectAllSplitsFundsBetweenReceiverAndSplits() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(
            receiver1,
            splitsReceivers(receiver2, totalWeight / 4, receiver3, totalWeight / 2)
        );
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        assertCollectableAll(receiver3, 0);
        // Receiver1 had 1 second paying 10 per second, of which 3/4 is split, which is 7
        collectAll(receiver1, 3, 7);
        // Receiver2 got 1/3 of 7 split from receiver1, which is 2
        collectAll(receiver2, 2);
        // Receiver3 got 2/3 of 7 split from receiver1, which is 5
        collectAll(receiver3, 5);
    }

    function testReceiveSomeDripsCycles() public {
        // Enough for 3 cycles
        uint128 amt = dripsHub.cycleSecs() * 3;
        warpToCycleEnd();
        setDrips(user, 0, amt, dripsReceivers(receiver, 1));
        warpToCycleEnd();
        warpToCycleEnd();
        warpToCycleEnd();
        receiveDrips({
            user: receiver,
            maxCycles: 2,
            expectedReceivedAmt: dripsHub.cycleSecs() * 2,
            expectedReceivedCycles: 2,
            expectedAmtAfter: dripsHub.cycleSecs(),
            expectedCyclesAfter: 1
        });
        collectAll(receiver, amt);
    }

    function testReceiveAllDripsCycles() public {
        // Enough for 3 cycles
        uint128 amt = dripsHub.cycleSecs() * 3;
        warpToCycleEnd();
        setDrips(user, 0, amt, dripsReceivers(receiver, 1));
        warpToCycleEnd();
        warpToCycleEnd();
        warpToCycleEnd();

        receiveDrips(receiver, dripsHub.cycleSecs() * 3, 3);

        collectAll(receiver, amt);
    }

    function testFundsGivenFromUserCanBeCollected() public {
        give(user, receiver, 10);
        collectAll(receiver, 10);
    }

    function testSplitSplitsFundsReceivedFromAllSources() public {
        uint32 totalWeight = dripsHub.TOTAL_SPLITS_WEIGHT();
        // Gives
        give(user2, user1, 1);

        // Drips
        setDrips(user2, 0, 2, dripsReceivers(user1, 2));
        warpToCycleEnd();
        receiveDrips(user1, 2, 1);

        // Splits
        setSplits(receiver2, splitsReceivers(user1, totalWeight));
        give(receiver2, receiver2, 5);
        split(receiver2, 0, 5);

        // Split the received 1 + 2 + 5 = 8
        setSplits(user1, splitsReceivers(receiver1, totalWeight / 4));
        split(user1, 6, 2);
        collect(user1, 6);
    }

    function testRegisterApp() public {
        address appAddr = address(0x1234);
        uint32 appId = dripsHub.nextAppId();
        assertEq(address(0), dripsHub.appAddress(appId), "Invalid nonexistent app address");
        assertEq(appId, dripsHub.registerApp(appAddr), "Invalid assigned app ID");
        assertEq(appAddr, dripsHub.appAddress(appId), "Invalid app address");
        assertEq(appId + 1, dripsHub.nextAppId(), "Invalid next app ID");
    }

    function testUpdateAppAddress() public {
        uint32 appId = dripsHub.registerApp(address(this));
        assertEq(address(this), dripsHub.appAddress(appId), "Invalid app address before");
        address newAppAddr = address(0x1234);
        dripsHub.updateAppAddress(appId, newAppAddr);
        assertEq(newAppAddr, dripsHub.appAddress(appId), "Invalid app address after");
    }

    function testUpdateAppAddressRevertsWhenNotCalledByTheApp() public {
        uint32 appId = dripsHub.registerApp(address(0x1234));
        try dripsHub.updateAppAddress(appId, address(0x5678)) {
            assertTrue(false, "UpdateAppAddress hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid collect revert reason");
        }
    }

    function testCollectRevertsWhenNotCalledByTheApp() public {
        try dripsHub.collect(calcUserId(dripsHub.nextAppId(), 0), defaultErc20) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid collect revert reason");
        }
    }

    function testCollectAllRevertsWhenNotCalledByTheApp() public {
        try
            dripsHub.collectAll(
                calcUserId(dripsHub.nextAppId(), 0),
                defaultErc20,
                new SplitsReceiver[](0)
            )
        {
            assertTrue(false, "CollectAll hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid collectAll revert reason");
        }
    }

    function testDripsInDifferentTokensAreIndependent() public {
        uint32 cycleLength = dripsHub.cycleSecs();
        // Covers 1.5 cycles of dripping
        setDrips(
            defaultErc20,
            user,
            0,
            9 * cycleLength,
            dripsReceivers(receiver1, 4, receiver2, 2)
        );

        warpToCycleEnd();
        // Covers 2 cycles of dripping
        setDrips(otherErc20, user, 0, 6 * cycleLength, dripsReceivers(receiver1, 3));

        warpToCycleEnd();
        // receiver1 had 1.5 cycles of 4 per second
        collectAll(defaultErc20, receiver1, 6 * cycleLength);
        // receiver1 had 1.5 cycles of 2 per second
        collectAll(defaultErc20, receiver2, 3 * cycleLength);
        // receiver1 had 1 cycle of 3 per second
        collectAll(otherErc20, receiver1, 3 * cycleLength);
        // receiver2 received nothing
        collectAll(otherErc20, receiver2, 0);

        warpToCycleEnd();
        // receiver1 received nothing
        collectAll(defaultErc20, receiver1, 0);
        // receiver2 received nothing
        collectAll(defaultErc20, receiver2, 0);
        // receiver1 had 1 cycle of 3 per second
        collectAll(otherErc20, receiver1, 3 * cycleLength);
        // receiver2 received nothing
        collectAll(otherErc20, receiver2, 0);
    }

    function testSetDripsRevertsWhenNotCalledByTheApp() public {
        try
            dripsHub.setDrips(
                calcUserId(dripsHub.nextAppId(), 0),
                defaultErc20,
                dripsReceivers(),
                0,
                dripsReceivers()
            )
        {
            assertTrue(false, "SetDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid setDrips revert reason");
        }
    }

    function testGiveRevertsWhenNotCalledByTheApp() public {
        try dripsHub.give(calcUserId(dripsHub.nextAppId(), 0), 0, defaultErc20, 1) {
            assertTrue(false, "Give hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid give revert reason");
        }
    }

    function testSetSplitsRevertsWhenNotCalledByTheApp() public {
        try dripsHub.setSplits(calcUserId(dripsHub.nextAppId(), 0), splitsReceivers()) {
            assertTrue(false, "SetSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_APP, "Invalid setSplits revert reason");
        }
    }

    function testAnyoneCanCollectForAnyoneUsingAddressApp() public {
        give(user, receiver1, 5);
        split(receiver1, 5, 0);
        assertCollectable(receiver1, 5);
        uint256 balanceBefore = defaultErc20.balanceOf(address(receiver1));

        uint128 collected = addressApp.collect(address(receiver1), defaultErc20);

        assertEq(collected, 5, "Invalid collected amount");
        assertCollectable(receiver1, 0);
        assertBalance(receiver1, balanceBefore + 5);
    }

    function testAnyoneCanCollectAllForAnyoneUsingAddressApp() public {
        give(user, receiver1, 5);
        assertCollectableAll(receiver1, 5);
        uint256 balanceBefore = defaultErc20.balanceOf(address(receiver1));

        (uint128 collected, uint128 split) = addressApp.collectAll(
            address(receiver1),
            defaultErc20,
            splitsReceivers()
        );

        assertEq(collected, 5, "Invalid collected amount");
        assertEq(split, 0, "Invalid split amount");
        assertCollectableAll(receiver1, 0);
        assertBalance(receiver1, balanceBefore + 5);
    }

    function testAdminCanBeChanged() public {
        assertEq(dripsHub.admin(), address(admin));
        admin.changeAdmin(address(nonAdmin));
        assertEq(dripsHub.admin(), address(nonAdmin));
    }

    function testOnlyAdminCanChangeAdmin() public {
        try nonAdmin.changeAdmin(address(0x1234)) {
            assertTrue(false, "ChangeAdmin hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid changeAdmin revert reason");
        }
    }

    function testContractCanBeUpgraded() public {
        uint32 newCycleLength = dripsHub.cycleSecs() + 1;
        DripsHub newLogic = new DripsHub(newCycleLength, dripsHub.reserve());
        admin.upgradeTo(address(newLogic));
        assertEq(dripsHub.cycleSecs(), newCycleLength, "Invalid new cycle length");
    }

    function testOnlyAdminCanUpgradeContract() public {
        try nonAdmin.upgradeTo(address(0)) {
            assertTrue(false, "ChangeAdmin hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid changeAdmin revert reason");
        }
    }

    function testContractCanBePausedAndUnpaused() public {
        assertTrue(!dripsHub.paused(), "Initially paused");
        admin.pause();
        assertTrue(dripsHub.paused(), "Pausing failed");
        admin.unpause();
        assertTrue(!dripsHub.paused(), "Unpausing failed");
    }

    function testOnlyUnpausedContractCanBePaused() public {
        admin.pause();
        try admin.pause() {
            assertTrue(false, "Pause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid pause revert reason");
        }
    }

    function testOnlyPausedContractCanBeUnpaused() public {
        try admin.unpause() {
            assertTrue(false, "Unpause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Contract not paused", "Invalid unpause revert reason");
        }
    }

    function testOnlyAdminCanPause() public {
        try nonAdmin.pause() {
            assertTrue(false, "Pause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid pause revert reason");
        }
    }

    function testOnlyAdminCanUnpause() public {
        admin.pause();
        try nonAdmin.unpause() {
            assertTrue(false, "Unpause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid unpause revert reason");
        }
    }

    function testCollectAllCanBePaused() public {
        admin.pause();
        try user.collectAll(address(user), defaultErc20, splitsReceivers()) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid collect revert reason");
        }
    }

    function testReceiveDripsCanBePaused() public {
        admin.pause();
        try dripsHub.receiveDrips(user.userId(), defaultErc20, 1) {
            assertTrue(false, "ReceiveDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid receiveDrips revert reason");
        }
    }

    function testSplitCanBePaused() public {
        admin.pause();
        try dripsHub.split(user.userId(), defaultErc20, splitsReceivers()) {
            assertTrue(false, "Split hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid split revert reason");
        }
    }

    function testCollectCanBePaused() public {
        admin.pause();
        try user.collect(address(user), defaultErc20) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid collect revert reason");
        }
    }

    function testSetDripsCanBePaused() public {
        admin.pause();
        try user.setDrips(defaultErc20, dripsReceivers(), 1, dripsReceivers()) {
            assertTrue(false, "SetDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid setDrips revert reason");
        }
    }

    function testGiveCanBePaused() public {
        admin.pause();
        try user.give(0, defaultErc20, 1) {
            assertTrue(false, "Give hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid give revert reason");
        }
    }

    function testSetSplitsCanBePaused() public {
        admin.pause();
        try user.setSplits(splitsReceivers()) {
            assertTrue(false, "SetSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid setSplits revert reason");
        }
    }

    function testRegisterAppCanBePaused() public {
        admin.pause();
        try dripsHub.registerApp(address(0x1234)) {
            assertTrue(false, "RegisterApp hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid registerApp revert reason");
        }
    }

    function testUpdateAppAddressCanBePaused() public {
        uint32 appId = dripsHub.registerApp(address(this));
        admin.pause();
        try dripsHub.updateAppAddress(appId, address(0x1234)) {
            assertTrue(false, "UpdateAppAddress hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid updateAppAddress revert reason");
        }
    }
}
