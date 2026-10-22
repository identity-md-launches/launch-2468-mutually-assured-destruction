// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "src/MADToken.sol";

/// @dev Models the constructor and exact payouts of a contract deployer in one transaction.
/// This is a transfer-flow fixture, not a replacement for the protected Uniswap integration checks.
contract MADTokenLaunchFixture {
    MADToken public immutable token;

    constructor(address distributor, address pool, address recipient, uint256 poolAmount) {
        token = new MADToken();
        require(token.balanceOf(address(this)) == 1_000_000_000e18, "constructor allocation");
        require(token.transfer(distributor, 100_000_000e18), "swarm transfer");
        require(token.transfer(pool, poolAmount), "pool transfer");
        require(token.transfer(recipient, 900_000_000e18 - poolAmount), "remainder transfer");
    }
}

/// @notice Boundary values, independent allowances, and atomic failures complement MADTokenTest.
/// forge-config: default.fuzz.runs = 1000
contract MADTokenEdgeCasesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal deployer = makeAddr("edge deployer");
    address internal alice = makeAddr("edge alice");
    address internal bob = makeAddr("edge bob");
    address internal spender = makeAddr("edge spender");
    MADToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();
    }

    function test_oneMinorUnitTransfersExactlyAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 1);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_selfTransfersAtZeroOneAndFullSupplyPreserveBalanceAndAllowance() public {
        _approve(deployer, spender, 17);
        uint256[3] memory amounts = [uint256(0), uint256(1), SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectEmit(true, true, false, true, address(token));
            emit Transfer(deployer, deployer, amounts[i]);
            vm.prank(deployer);
            assertTrue(token.transfer(deployer, amounts[i]));
            _assertBalances(SUPPLY, 0, 0);
            assertEq(token.allowance(deployer, spender), 17);
        }
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(deployer, SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumTransferRevertsWithoutChangingState() public {
        _approve(deployer, spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_zeroTransferFromWithoutAllowanceEmitsAndDoesNotChangeState() public {
        // Both a funded owner and an empty owner may transfer zero through an unapproved spender.
        address[2] memory owners = [deployer, alice];
        for (uint256 i; i < owners.length; ++i) {
            vm.expectEmit(true, true, false, true, address(token));
            emit Transfer(owners[i], bob, 0);
            vm.prank(spender);
            assertTrue(token.transferFrom(owners[i], bob, 0));
            assertEq(token.allowance(owners[i], spender), 0);
            _assertBalances(SUPPLY, 0, 0);
        }
    }

    function test_zeroAmountDoesNotPermitZeroRecipientOrSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 0);
        assertEq(token.allowance(deployer, address(0)), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_finiteAllowanceIsExhaustedAndCannotBeReusedAfterRefill() public {
        _approve(deployer, spender, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(0, SUPPLY, 0);

        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumMinusOneAllowanceIsFinite() public {
        _approve(deployer, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), type(uint256).max - 1 - SUPPLY);
        _assertBalances(0, SUPPLY, 0);
    }

    function test_infiniteAllowanceSurvivesRepeatedFullBalanceSpending() public {
        _approve(deployer, spender, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            vm.prank(spender);
            assertTrue(token.transferFrom(deployer, alice, SUPPLY));
            _assertBalances(0, SUPPLY, 0);
            assertEq(token.allowance(deployer, spender), type(uint256).max);
            vm.prank(alice);
            assertTrue(token.transfer(deployer, SUPPLY));
        }
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_replacingInfiniteAllowanceWithFiniteThenRevokingTakesEffect() public {
        _approve(deployer, spender, type(uint256).max);
        _approve(deployer, spender, 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), 1);

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 0);
        _approve(deployer, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_transferFromToOwnerConsumesAllowanceWithoutCreatingTokens() public {
        _approve(deployer, spender, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, deployer, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_transferFromByOwnerStillNeedsSelfAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
        _assertBalances(SUPPLY, 0, 0);

        _approve(deployer, deployer, 1);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, deployer), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_spenderCanBeRecipient() public {
        _approve(deployer, alice, 1);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, alice), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_approvalsAreScopedToBothOwnerAndSpender() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 10));
        _approve(deployer, spender, 7);
        _approve(alice, spender, 3);
        _approve(deployer, bob, 5);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 2));
        assertEq(token.allowance(alice, spender), 1);
        assertEq(token.allowance(deployer, spender), 7);
        assertEq(token.allowance(deployer, bob), 5);
        assertEq(token.allowance(alice, bob), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        _assertBalances(SUPPLY - 10, 8, 2);
    }

    function test_directTransferDoesNotSpendOrGrantAllowances() public {
        _approve(deployer, spender, 7);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 7));
        assertEq(token.allowance(deployer, spender), 7);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(deployer, alice), 0);
        _assertBalances(SUPPLY - 7, 7, 0);
    }

    function test_attachingEtherToTransferRevertsAndRefundsValue() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1 ether}(abi.encodeCall(token.transfer, (alice, 1)));
        assertFalse(ok);
        assertEq(deployer.balance, 1 ether);
        assertEq(address(token).balance, 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        _assertBalances(SUPPLY - amount, amount, 0);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, amount));
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_splitTransfersEqualOneTransfer(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, first));
        vm.prank(deployer);
        assertTrue(token.transfer(alice, second));
        _assertBalances(SUPPLY - first - second, first + second, 0);

        vm.prank(alice);
        assertTrue(token.transfer(deployer, first + second));
        vm.prank(deployer);
        assertTrue(token.transfer(alice, first + second));
        _assertBalances(SUPPLY - first - second, first + second, 0);
    }

    function testFuzz_approvalReplacesRatherThanAddsAndCanBeRevoked(uint256 first, uint256 replacement) public {
        _approve(deployer, spender, first);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, replacement);
        _approve(deployer, spender, replacement);
        assertEq(token.allowance(deployer, spender), replacement);
        // Repeating the same approval is idempotent, including at uint256's maximum.
        _approve(deployer, spender, replacement);
        assertEq(token.allowance(deployer, spender), replacement);
        _approve(deployer, spender, 0);
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_failedTransferFromPreservesAllowanceAndBalances(uint256 held, uint256 requested, bool infinite)
        public
    {
        held = bound(held, 0, SUPPLY);
        requested = bound(requested, held + 1, type(uint256).max);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, held));
        uint256 allowed = infinite ? type(uint256).max : requested;
        _approve(alice, spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, requested));
        vm.prank(spender);
        token.transferFrom(alice, bob, requested);
        assertEq(token.allowance(alice, spender), allowed, "failed transfer consumed allowance");
        _assertBalances(SUPPLY - held, held, 0);
    }

    function testFuzz_invalidReceiverRollsBackAllowanceSpending(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 allowed = infinite ? type(uint256).max : amount;
        _approve(deployer, spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.allowance(deployer, spender), allowed, "invalid receiver consumed allowance");
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_exceedingFiniteAllowanceByOneIsAtomic(uint256 allowed) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        _approve(deployer, spender, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, allowed + 1);
        assertEq(token.allowance(deployer, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_partialSpendingThenReplacementUsesOnlyNewAllowance(
        uint256 original,
        uint256 spent,
        uint256 replacement
    ) public {
        original = bound(original, 1, SUPPLY);
        spent = bound(spent, 1, original);
        replacement = bound(replacement, 0, SUPPLY - spent);
        _approve(deployer, spender, original);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, spent));
        assertEq(token.allowance(deployer, spender), original - spent);

        _approve(deployer, spender, replacement);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, replacement));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - spent - replacement, spent, replacement);
    }

    function testFuzz_factoryPayoutsAndDistributorClaimsArriveWhole(uint256 poolAmount, uint256 claimAmount) public {
        poolAmount = bound(poolAmount, 0, 900_000_000e18);
        claimAmount = bound(claimAmount, 0, 100_000_000e18);
        MADTokenLaunchFixture factory = new MADTokenLaunchFixture(alice, bob, deployer, poolAmount);
        MADToken launched = factory.token();
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(address(this)), 0, "caller must not receive the constructor mint");
        assertEq(launched.balanceOf(alice), 100_000_000e18);
        assertEq(launched.balanceOf(bob), poolAmount);
        assertEq(launched.balanceOf(deployer), 900_000_000e18 - poolAmount);

        vm.prank(alice);
        assertTrue(launched.transfer(spender, claimAmount));
        assertEq(launched.balanceOf(alice), 100_000_000e18 - claimAmount);
        assertEq(launched.balanceOf(spender), claimAmount);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(
            launched.balanceOf(alice) + launched.balanceOf(bob) + launched.balanceOf(deployer)
                + launched.balanceOf(spender),
            SUPPLY
        );
    }

    function _approve(address owner, address delegate, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(delegate, amount));
    }

    function _assertBalances(uint256 deployerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        assertEq(token.balanceOf(deployer), deployerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(deployerBalance + aliceBalance + bobBalance, SUPPLY);
    }
}
