// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Arcelo} from "../src/Arcelo.sol";
import {FeeOnTransferMockERC20, MockERC20} from "./mocks/MockERC20.sol";

contract ArceloV2 is Arcelo {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ArceloTest is Test {
    uint256 internal constant GENESIS = 1_715_558_400; // Monday, 2024-05-13 00:00:00 UTC
    uint256 internal constant BET = 1_000e6;
    uint256 internal constant MAX_BET = 1_000_000e6;
    uint256 internal backendKey = 0xA11CE;

    Arcelo internal arcelo;
    MockERC20 internal token;
    MockERC20 internal otherToken;
    address internal owner = address(0xA11CE);
    address internal backendSigner;
    address internal player = address(0x1000);
    address internal player2 = address(0x2000);

    function setUp() public {
        vm.warp(GENESIS + 1 days);
        backendSigner = vm.addr(backendKey);
        token = new MockERC20("Mock USDC", "mUSDC", 6);
        otherToken = new MockERC20("Mock cUSD", "mcUSD", 18);

        Arcelo implementation = new Arcelo();
        bytes memory initData =
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS, backendSigner, 2 hours, address(token), 1, MAX_BET));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        arcelo = Arcelo(payable(address(proxy)));

        token.mint(player, MAX_BET);
        token.mint(player2, MAX_BET);
        otherToken.mint(player, MAX_BET);
        vm.deal(player, 100 ether);
        vm.deal(player2, 100 ether);
    }

    function testInitializeAndImplementationCannotBeInitialized() public {
        assertEq(arcelo.owner(), owner);
        assertEq(arcelo.genesisWeekStart(), GENESIS);
        assertEq(arcelo.backendSigner(), backendSigner);
        assertEq(arcelo.maxSessionDuration(), 2 hours);
        assertEq(arcelo.gameToken(), address(token));

        (bool supported, uint256 minBet, uint256 maxBet) = arcelo.tokenConfig(address(token));
        assertTrue(supported);
        assertEq(minBet, 1);
        assertEq(maxBet, MAX_BET);

        Arcelo implementation = new Arcelo();
        vm.expectRevert();
        implementation.initialize(owner, GENESIS, backendSigner, 1 hours, address(token), 1, MAX_BET);
    }

    function testInvalidInitializeConfigReverts() public {
        Arcelo implementation = new Arcelo();
        vm.expectRevert(Arcelo.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Arcelo.initialize, (address(0), GENESIS, backendSigner, 1 hours, address(token), 1, MAX_BET))
        );

        implementation = new Arcelo();
        vm.expectRevert(Arcelo.BackendSignerRequired.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS, address(0), 1 hours, address(token), 1, MAX_BET))
        );

        implementation = new Arcelo();
        vm.expectRevert(Arcelo.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS, backendSigner, 1 hours, address(0), 1, MAX_BET))
        );

        implementation = new Arcelo();
        vm.expectRevert(Arcelo.InvalidBetRange.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS, backendSigner, 1 hours, address(token), 0, MAX_BET))
        );

        implementation = new Arcelo();
        vm.expectRevert(Arcelo.InvalidGenesisWeekStart.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS + 1, backendSigner, 1 hours, address(token), 1, MAX_BET))
        );
    }

    function testOwnerCanOnlyConfigureUsdcGameToken() public {
        vm.prank(owner);
        arcelo.setSupportedToken(address(token), true, 10, 100);

        (bool supported, uint256 minBet, uint256 maxBet) = arcelo.tokenConfig(address(token));
        assertTrue(supported);
        assertEq(minBet, 10);
        assertEq(maxBet, 100);

        vm.prank(owner);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.setSupportedToken(address(otherToken), true, 10, 100);

        vm.prank(player);
        vm.expectRevert();
        arcelo.setSupportedToken(address(token), true, 10, 100);

        vm.prank(owner);
        vm.expectRevert(Arcelo.InvalidBetRange.selector);
        arcelo.setSupportedToken(address(token), true, 0, 100);
    }

    function testUsdcDepositWithdraw() public {
        _depositUsdc(player, 500e6);
        assertEq(arcelo.playerBalance(player, address(token)), 500e6);

        uint256 beforeBalance = token.balanceOf(player);
        vm.prank(player);
        arcelo.withdraw(address(token), 200e6);

        assertEq(arcelo.playerBalance(player, address(token)), 300e6);
        assertEq(token.balanceOf(player), beforeBalance + 200e6);
    }

    function testDepositCreditsActualReceivedAmount() public {
        FeeOnTransferMockERC20 feeToken = new FeeOnTransferMockERC20("Fee USDC", "fUSDC", 6);
        Arcelo feeArcelo = _deployWithToken(address(feeToken));
        feeToken.mint(player, 1_000e6);

        vm.startPrank(player);
        feeToken.approve(address(feeArcelo), 1_000e6);
        feeArcelo.deposit(address(feeToken), 1_000e6);
        vm.stopPrank();

        assertEq(feeArcelo.playerBalance(player, address(feeToken)), 990e6);
        assertEq(feeToken.balanceOf(address(feeArcelo)), 990e6);
    }

    function testOnlyUsdcIsAccepted() public {
        vm.prank(player);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.deposit{value: 1}(address(0), 1);

        vm.startPrank(player);
        otherToken.approve(address(arcelo), 100);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.deposit(address(otherToken), 100);
        vm.stopPrank();

        vm.prank(player);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.startGame(address(otherToken), 1, 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.seedPrizePool(address(otherToken), 1, 0);

        vm.prank(owner);
        vm.expectRevert(Arcelo.UnsupportedToken.selector);
        arcelo.distributeWeeklyPrize(address(otherToken), 0);
    }

    function testDepositWithdrawAndAdminInputValidation() public {
        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidAmount.selector);
        arcelo.deposit(address(token), 0);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidNativeValue.selector);
        arcelo.deposit{value: 1}(address(token), 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidAmount.selector);
        arcelo.withdraw(address(token), 0);

        vm.prank(player);
        vm.expectRevert(Arcelo.InsufficientBalance.selector);
        arcelo.withdraw(address(token), 1);

        vm.prank(owner);
        vm.expectRevert(Arcelo.ZeroAddress.selector);
        arcelo.withdrawRevenue(address(token), payable(address(0)), 1);

        vm.prank(owner);
        vm.expectRevert(Arcelo.InvalidAmount.selector);
        arcelo.withdrawRevenue(address(token), payable(owner), 0);

        vm.prank(owner);
        vm.expectRevert(Arcelo.InvalidSessionDuration.selector);
        arcelo.setMaxSessionDuration(0);

        vm.prank(owner);
        vm.expectRevert(Arcelo.InvalidSessionDuration.selector);
        arcelo.setMaxSessionDuration(8 days);

        vm.prank(owner);
        vm.expectRevert(Arcelo.BackendSignerRequired.selector);
        arcelo.setBackendSigner(address(0));

        vm.prank(owner);
        vm.expectRevert(Arcelo.ExitSignatureCannotBeDisabled.selector);
        arcelo.setExitSignatureRequired(false);
    }

    function testStartGameSplitsBetAndPreventsSecondSession() public {
        _depositUsdc(player, 101);

        vm.prank(player);
        bytes32 sessionId = arcelo.startGame(address(token), 101, 1);

        assertEq(arcelo.playerBalance(player, address(token)), 0);
        assertEq(arcelo.prizePoolByWeek(address(token), 0), 81);
        assertEq(arcelo.platformRevenue(address(token)), 20);
        assertEq(arcelo.activeSessionOf(player), sessionId);

        _depositUsdc(player, 1);
        vm.prank(player);
        vm.expectRevert(Arcelo.ActiveSessionExists.selector);
        arcelo.startGame(address(token), 1, 1);
    }

    function testStartGameRejectsInvalidBetAndGameId() public {
        _depositUsdc(player, MAX_BET);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidBetRange.selector);
        arcelo.startGame(address(token), 0, 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidBetRange.selector);
        arcelo.startGame(address(token), MAX_BET + 1, 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidGameId.selector);
        arcelo.startGame(address(token), BET, 0);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidGameId.selector);
        arcelo.startGame(address(token), BET, 6);
    }

    function testFuzzStartGameSplitConservesBet(uint256 bet) public {
        bet = bound(bet, 1, MAX_BET);
        _depositUsdc(player, bet);

        vm.prank(player);
        arcelo.startGame(address(token), bet, 1);

        uint256 expectedRevenue = (bet * 2000) / 10_000;
        uint256 expectedPrize = bet - expectedRevenue;
        assertEq(arcelo.platformRevenue(address(token)), expectedRevenue);
        assertEq(arcelo.prizePoolByWeek(address(token), 0), expectedPrize);
        assertEq(arcelo.playerBalance(player, address(token)), 0);
        assertEq(token.balanceOf(address(arcelo)), expectedRevenue + expectedPrize);
    }

    function testExitMintsArcUpdatesLeaderboardAndClearsSession() public {
        bytes32 sessionId = _startUsdc(player, BET, 2);

        _exitWithSignature(player, sessionId, 3);

        assertEq(arcelo.arcBalanceByWeek(0, player), 30);
        assertEq(arcelo.activeSessionOf(player), bytes32(0));
        assertEq(arcelo.rankOf(0, player), 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidSession.selector);
        arcelo.exitGame(sessionId, 1, 0, "");
    }

    function testExitRejectsWrongPlayerAndZeroCheckpoint() public {
        bytes32 sessionId = _startUsdc(player, BET, 1);

        vm.prank(player2);
        vm.expectRevert(Arcelo.NotSessionPlayer.selector);
        arcelo.exitGame(sessionId, 1, 0, "");

        vm.prank(player);
        vm.expectRevert(Arcelo.ZeroCheckpoints.selector);
        arcelo.exitGame(sessionId, 0, 0, "");
    }

    function testForfeitAndExpiryAwardNoArc() public {
        bytes32 forfeited = _startUsdc(player, BET, 1);
        vm.prank(player);
        arcelo.forfeitGame(forfeited);
        assertEq(arcelo.arcBalanceByWeek(0, player), 0);
        assertEq(arcelo.activeSessionOf(player), bytes32(0));

        bytes32 expired = _startUsdc(player, BET, 1);
        vm.expectRevert(Arcelo.InvalidSession.selector);
        arcelo.expireSession(expired);

        vm.warp(block.timestamp + 2 hours);
        arcelo.expireSession(expired);
        assertEq(arcelo.arcBalanceByWeek(0, player), 0);
        assertEq(arcelo.activeSessionOf(player), bytes32(0));
    }

    function testLeaderboardTopTenSortingAndTieBreak() public {
        address lower = address(0x0100);
        address higher = address(0x0200);
        _playUsdc(lower, BET, 5, 5);
        _playUsdc(higher, BET, 5, 5);

        assertEq(arcelo.rankOf(0, lower), 1);
        assertEq(arcelo.rankOf(0, higher), 2);

        for (uint160 i = 1; i <= 11; ++i) {
            _playUsdc(address(0x3000 + i), BET, 1, i);
        }

        (address[] memory players, uint256[] memory scores) = arcelo.getTopPlayers(0);
        assertEq(players.length, 10);
        assertEq(scores.length, 10);
        assertEq(scores[0], 110);
        assertEq(arcelo.rankOf(0, address(0x3001)), 0);
    }

    function testOldWeekDoesNotPolluteCurrentWeek() public {
        _playUsdc(player, BET, 1, 3);
        _warpPastDistributionWindow(0);

        assertEq(arcelo.currentWeekId(), 1);
        assertEq(arcelo.currentArcBalanceOf(player), 0);
        (address[] memory players,) = arcelo.getCurrentTopPlayers();
        assertEq(players.length, 0);
    }

    function testPrizeDistributionCreditsClaimableAndRollsRemainder() public {
        _playUsdc(player, BET, 1, 1);
        uint256 winnerBefore = token.balanceOf(player);
        _warpPastDistributionWindow(0);

        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);

        assertEq(token.balanceOf(player), winnerBefore);
        assertEq(arcelo.claimablePrize(player, address(token)), 280e6);
        vm.prank(player);
        arcelo.claimPrize(address(token), 280e6);
        assertEq(token.balanceOf(player) - winnerBefore, 280e6);
        assertEq(arcelo.prizePoolByWeek(address(token), 1), 520e6);

        vm.prank(owner);
        vm.expectRevert(Arcelo.PrizeAlreadyDistributed.selector);
        arcelo.distributeWeeklyPrize(address(token), 0);
    }

    function testPrizeDistributionPaysExactPercentagesForTenWinners() public {
        address[10] memory winners;
        uint256[10] memory expected = [
            uint256(2_800e6),
            uint256(1_600e6),
            uint256(1_200e6),
            uint256(800e6),
            uint256(800e6),
            uint256(160e6),
            uint256(160e6),
            uint256(160e6),
            uint256(160e6),
            uint256(160e6)
        ];

        for (uint160 i; i < 10; ++i) {
            address p = address(0x7000 + i);
            winners[i] = p;
            _playUsdc(p, BET, 1, 10 - i);
        }

        _warpPastDistributionWindow(0);
        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);

        for (uint256 i; i < 10; ++i) {
            assertEq(arcelo.claimablePrize(winners[i], address(token)), expected[i]);
        }
        assertEq(arcelo.prizePoolByWeek(address(token), 1), 0);
    }

    function testPrizeDistributionRejectsCurrentWeek() public {
        vm.prank(owner);
        vm.expectRevert(Arcelo.WeekNotEnded.selector);
        arcelo.distributeWeeklyPrize(address(token), 0);
    }

    function testPrizeDistributionWaitsForSessionWindow() public {
        _playUsdc(player, BET, 1, 1);
        vm.warp(GENESIS + 7 days + 1);

        vm.prank(owner);
        vm.expectRevert(Arcelo.PrizeDistributionPendingSessionWindow.selector);
        arcelo.distributeWeeklyPrize(address(token), 0);

        _warpPastDistributionWindow(0);
        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);

        assertEq(arcelo.claimablePrize(player, address(token)), 280e6);
    }

    function testDisabledUsdcStillAllowsWithdrawAndPrizeDistribution() public {
        _playUsdc(player, BET, 1, 1);
        _depositUsdc(player2, BET);

        vm.prank(owner);
        arcelo.setSupportedToken(address(token), false, 1, MAX_BET);

        vm.prank(player2);
        arcelo.withdraw(address(token), BET);

        _warpPastDistributionWindow(0);
        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);

        assertEq(arcelo.claimablePrize(player, address(token)), 280e6);
    }

    function testSeedPrizePoolUsdc() public {
        _approveUsdc(player, 500e6);
        vm.prank(player);
        arcelo.seedPrizePool(address(token), 500e6, 0);
        assertEq(arcelo.prizePoolByWeek(address(token), 0), 500e6);

        _warpPastDistributionWindow(0);
        vm.prank(player);
        vm.expectRevert(Arcelo.PastWeek.selector);
        arcelo.seedPrizePool(address(token), 1, 0);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidAmount.selector);
        arcelo.seedPrizePool(address(token), 0, 1);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidNativeValue.selector);
        arcelo.seedPrizePool{value: 1}(address(token), 1, 1);
    }

    function testSeedPrizePoolCreditsActualReceivedAmount() public {
        FeeOnTransferMockERC20 feeToken = new FeeOnTransferMockERC20("Fee USDC", "fUSDC", 6);
        Arcelo feeArcelo = _deployWithToken(address(feeToken));
        feeToken.mint(player, 1_000e6);

        vm.startPrank(player);
        feeToken.approve(address(feeArcelo), 1_000e6);
        feeArcelo.seedPrizePool(address(feeToken), 1_000e6, 0);
        vm.stopPrank();

        assertEq(feeArcelo.prizePoolByWeek(address(feeToken), 0), 990e6);
        assertEq(feeToken.balanceOf(address(feeArcelo)), 990e6);
    }

    function testDirectNativeTransferReverts() public {
        vm.prank(player);
        (bool success, bytes memory data) = payable(address(arcelo)).call{value: 1}("");
        assertFalse(success);
        assertEq(data, abi.encodeWithSelector(Arcelo.DirectNativeTransferUnsupported.selector));
    }

    function testFuzzPrizeDistributionRolloverConservesPool(uint256 pool) public {
        pool = bound(pool, 1, MAX_BET);

        _playUsdc(player, BET, 1, 1);
        _approveUsdc(player2, pool);
        vm.prank(player2);
        arcelo.seedPrizePool(address(token), pool, 0);

        uint256 existingPool = 800e6;
        uint256 totalPool = existingPool + pool;

        _warpPastDistributionWindow(0);
        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);

        uint256 expectedPaid = (totalPool * 3500) / 10_000;
        uint256 expectedRollover = totalPool - expectedPaid;
        assertEq(arcelo.claimablePrize(player, address(token)), expectedPaid);
        assertEq(arcelo.prizePoolByWeek(address(token), 1), expectedRollover);
        assertEq(
            token.balanceOf(address(arcelo)), arcelo.platformRevenue(address(token)) + expectedRollover + expectedPaid
        );
    }

    function testZeroWinnerDistributionRollsFullPool() public {
        _depositUsdc(player, BET);
        vm.prank(player);
        arcelo.startGame(address(token), BET, 1);

        _warpPastDistributionWindow(0);
        vm.prank(owner);
        arcelo.distributeWeeklyPrize(address(token), 0);
        assertEq(arcelo.prizePoolByWeek(address(token), 1), 800e6);
    }

    function testRevenueWithdrawalCannotTakePrizePool() public {
        _startUsdc(player, BET, 1);

        vm.prank(player);
        vm.expectRevert();
        arcelo.withdrawRevenue(address(token), payable(player), 200e6);

        uint256 beforeBalance = token.balanceOf(owner);
        vm.prank(owner);
        arcelo.withdrawRevenue(address(token), payable(owner), 200e6);
        assertEq(token.balanceOf(owner) - beforeBalance, 200e6);

        vm.prank(owner);
        vm.expectRevert(Arcelo.RevenueExceeded.selector);
        arcelo.withdrawRevenue(address(token), payable(owner), 800e6);
    }

    function testSignatureMode() public {
        bytes32 sessionId = _startUsdc(player, BET, 1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = arcelo.hashExit(player, sessionId, 1, 0, 4, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendKey, digest);

        vm.prank(player);
        arcelo.exitGame(sessionId, 4, deadline, abi.encodePacked(r, s, v));
        assertEq(arcelo.arcBalanceByWeek(0, player), 40);
    }

    function testSignatureModeRejectsWrongSignerAndExpiredDeadline() public {
        bytes32 sessionId = _startUsdc(player, BET, 1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = arcelo.hashExit(player, sessionId, 1, 0, 4, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);

        vm.prank(player);
        vm.expectRevert(Arcelo.InvalidExitSignature.selector);
        arcelo.exitGame(sessionId, 4, deadline, abi.encodePacked(r, s, v));

        (v, r, s) = vm.sign(backendKey, digest);
        vm.warp(deadline + 1);
        vm.prank(player);
        vm.expectRevert(Arcelo.SignatureExpired.selector);
        arcelo.exitGame(sessionId, 4, deadline, abi.encodePacked(r, s, v));
    }

    function testPauseBlocksUserFlows() public {
        vm.prank(owner);
        arcelo.pause();

        vm.prank(player);
        vm.expectRevert();
        arcelo.deposit(address(token), 1);

        vm.prank(owner);
        arcelo.unpause();

        _depositUsdc(player, BET);
        assertEq(arcelo.playerBalance(player, address(token)), BET);
    }

    function testPauseBlocksWithdrawStartExitAndSeed() public {
        _depositUsdc(player, 2 * BET);
        vm.prank(player);
        bytes32 sessionId = arcelo.startGame(address(token), BET, 1);

        vm.prank(owner);
        arcelo.pause();

        vm.prank(player);
        vm.expectRevert();
        arcelo.withdraw(address(token), 1);

        vm.prank(player2);
        vm.expectRevert();
        arcelo.startGame(address(token), 1, 1);

        vm.prank(player);
        vm.expectRevert();
        arcelo.exitGame(sessionId, 1, 0, "");

        vm.prank(player);
        vm.expectRevert();
        arcelo.seedPrizePool(address(token), 1, 0);
    }

    function testNonOwnerCannotUpgrade() public {
        ArceloV2 v2 = new ArceloV2();

        vm.prank(player);
        vm.expectRevert();
        arcelo.upgradeToAndCall(address(v2), "");
    }

    function testFuzzLeaderboardTopTenSorted(uint8[12] memory rawScores) public {
        for (uint160 i; i < 12; ++i) {
            uint256 checkpoints = bound(rawScores[i], 1, 200);
            _playUsdc(address(0x5000 + i), BET, 1, checkpoints);
        }

        (address[] memory players, uint256[] memory scores) = arcelo.getTopPlayers(0);
        assertEq(players.length, 10);

        for (uint256 i = 1; i < scores.length; ++i) {
            assertTrue(scores[i - 1] >= scores[i]);
            if (scores[i - 1] == scores[i]) {
                assertTrue(uint160(players[i - 1]) < uint160(players[i]));
            }
        }
    }

    function testFuzzConservationAfterDepositStartSeedWithdraw(uint256 depositAmount, uint256 bet, uint256 seedAmount)
        public
    {
        depositAmount = bound(depositAmount, 2, MAX_BET);
        bet = bound(bet, 1, depositAmount);
        seedAmount = bound(seedAmount, 1, MAX_BET);

        _depositUsdc(player, depositAmount);
        vm.prank(player);
        arcelo.startGame(address(token), bet, 1);

        _approveUsdc(player2, seedAmount);
        vm.prank(player2);
        arcelo.seedPrizePool(address(token), seedAmount, 0);

        uint256 withdrawable = depositAmount - bet;
        if (withdrawable > 0) {
            vm.prank(player);
            arcelo.withdraw(address(token), withdrawable);
        }

        uint256 accounted = arcelo.playerBalance(player, address(token)) + arcelo.prizePoolByWeek(address(token), 0)
            + arcelo.platformRevenue(address(token));
        assertEq(token.balanceOf(address(arcelo)), accounted);
    }

    function testUpgradePreservesStorage() public {
        bytes32 sessionId = _startUsdc(player, BET, 1);
        _exitWithSignature(player, sessionId, 2);

        ArceloV2 v2 = new ArceloV2();
        vm.prank(owner);
        arcelo.upgradeToAndCall(address(v2), "");

        ArceloV2 upgraded = ArceloV2(payable(address(arcelo)));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.gameToken(), address(token));
        assertEq(upgraded.playerBalance(player, address(token)), 0);
        assertEq(upgraded.prizePoolByWeek(address(token), 0), 800e6);
        assertEq(upgraded.platformRevenue(address(token)), 200e6);
        assertEq(upgraded.arcBalanceByWeek(0, player), 20);
        assertEq(upgraded.rankOf(0, player), 1);
    }

    function _approveUsdc(address p, uint256 amount) internal {
        token.mint(p, amount);
        vm.prank(p);
        token.approve(address(arcelo), amount);
    }

    function _deployWithToken(address gameToken) internal returns (Arcelo deployed) {
        Arcelo implementation = new Arcelo();
        bytes memory initData =
            abi.encodeCall(Arcelo.initialize, (owner, GENESIS, backendSigner, 2 hours, gameToken, 1, MAX_BET));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        deployed = Arcelo(payable(address(proxy)));
    }

    function _depositUsdc(address p, uint256 amount) internal {
        _approveUsdc(p, amount);
        vm.prank(p);
        arcelo.deposit(address(token), amount);
    }

    function _startUsdc(address p, uint256 bet, uint8 gameId) internal returns (bytes32 sessionId) {
        _depositUsdc(p, bet);
        vm.prank(p);
        sessionId = arcelo.startGame(address(token), bet, gameId);
    }

    function _playUsdc(address p, uint256 bet, uint8 gameId, uint256 checkpoints) internal {
        bytes32 sessionId = _startUsdc(p, bet, gameId);
        _exitWithSignature(p, sessionId, checkpoints);
    }

    function _exitWithSignature(address p, bytes32 sessionId, uint256 checkpoints) internal {
        (,,, uint8 gameId, uint256 weekId,,,) = arcelo.sessions(sessionId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = arcelo.hashExit(p, sessionId, gameId, weekId, checkpoints, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendKey, digest);

        vm.prank(p);
        arcelo.exitGame(sessionId, checkpoints, deadline, abi.encodePacked(r, s, v));
    }

    function _warpPastDistributionWindow(uint256 weekId) internal {
        vm.warp(arcelo.weekStart(weekId + 1) + arcelo.maxSessionDuration());
    }
}
