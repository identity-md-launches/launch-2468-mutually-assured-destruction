// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "src/MADToken.sol";

/// @dev All balances originate in the real constructor mint. No token deal/store cheatcodes.
/// The actor set is closed: every successful transfer stays inside it. The zero address and
/// an unapproved outsider are used only in failure probes and checked separately.
contract MADTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant ACTOR_COUNT = 4;
    MADToken public immutable token;
    address public immutable outsider;
    address[4] public actors;

    // Ghost accounting is derived from authorized inputs, never copied from post-call state.
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public lastApproval;
    mapping(address => mapping(address => uint256)) public spentSinceApproval;

    uint256 public directVolume;
    uint256 public delegatedVolume;
    uint256 public rejectedCalls;

    constructor() {
        actors = [address(this), makeAddr("invariant alice"), makeAddr("invariant bob"), makeAddr("invariant carol")];
        outsider = makeAddr("invariant unapproved outsider");
        token = new MADToken();
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / ACTOR_COUNT));
        }
        // Each actor begins with SUPPLY / 4. Seed finite and infinite approvals so delegated
        // transfers can move real value before the first randomized approve action.
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            _approve(actors[i], actors[(i + 1) % ACTOR_COUNT], SUPPLY);
            _approve(actors[i], actors[(i + 2) % ACTOR_COUNT], type(uint256).max);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _amount(amountSeed, expectedBalance(from)));
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), expectedBalance(from));
    }

    function selfTransfer(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        _transfer(actor, actor, _amount(amountSeed, expectedBalance(actor)));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        // Full uint256 range: an approval is not limited by supply or the owner's balance.
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 remaining = expectedAllowance(owner, spender);
        uint256 balance = expectedBalance(owner);
        uint256 amount = _amount(amountSeed, balance < remaining ? balance : remaining);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        sent[owner] += amount;
        received[to] += amount;
        if (lastApproval[owner][spender] != type(uint256).max) {
            spentSinceApproval[owner][spender] += amount;
        }
        delegatedVolume += amount;
    }

    function rejectOverdraw(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 balance = expectedBalance(owner);
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        _expectFailure(
            owner,
            abi.encodeCall(token.transfer, (_actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    function rejectOverspend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 remaining = expectedAllowance(owner, spender);
        // Infinite permission cannot be exceeded. Replace it with a finite permission, then
        // test its limit, rather than skipping this randomized action.
        if (remaining == type(uint256).max) {
            _approve(owner, spender, SUPPLY);
            remaining = SUPPLY;
        }
        uint256 amount = bound(amountSeed, remaining + 1, type(uint256).max);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, amount)
        );
    }

    function rejectUnapprovedCaller(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        _expectFailure(
            outsider,
            abi.encodeCall(token.transferFrom, (_actor(ownerSeed), _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, amount)
        );
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 remaining = expectedAllowance(owner, spender);
        uint256 balance = expectedBalance(owner);
        uint256 amount = _amount(amountSeed, balance < remaining ? balance : remaining);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function rejectPrivilegedCall(uint256 callerSeed, uint256 victimSeed, uint256 actionSeed) external {
        address victim = _actor(victimSeed);
        bytes memory data;
        uint256 action = actionSeed % 8;
        if (action == 0) data = abi.encodeWithSignature("mint(address,uint256)", victim, 1);
        else if (action == 1) data = abi.encodeWithSignature("mint(uint256)", 1);
        else if (action == 2) data = abi.encodeWithSignature("burn(uint256)", 1);
        else if (action == 3) data = abi.encodeWithSignature("burnFrom(address,uint256)", victim, 1);
        else if (action == 4) data = abi.encodeWithSignature("pause()");
        else if (action == 5) data = abi.encodeWithSignature("blacklist(address)", victim);
        else if (action == 6) data = abi.encodeWithSignature("freezeAccount(address)", victim);
        else data = abi.encodeWithSignature("seize(address)", victim);

        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "unexpected privileged entry point");
        rejectedCalls++;
    }

    function expectedBalance(address actor) public view returns (uint256) {
        return SUPPLY / ACTOR_COUNT + received[actor] - sent[actor];
    }

    function expectedAllowance(address owner, address spender) public view returns (uint256) {
        uint256 approved = lastApproval[owner][spender];
        return approved == type(uint256).max ? approved : approved - spentSinceApproval[owner][spender];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _amount(uint256 seed, uint256 maximum) internal pure returns (uint256) {
        // Bias towards zero, one minor unit, and draining the available balance/allowance.
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return maximum == 0 ? 0 : 1;
        if (seed % 4 == 2) return maximum;
        return bound(seed, 0, maximum);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        sent[from] += amount;
        received[to] += amount;
        directVolume += amount;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        lastApproval[owner][spender] = amount;
        spentSinceApproval[owner][spender] = 0;
    }

    function _expectFailure(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(token).call(data);
        assertFalse(ok, "invalid operation succeeded");
        assertEq(reason, expectedError, "unexpected failure reason");
        // No ghost balances or spending change on failure; the invariants therefore also
        // check rollback of every tracked balance and allowance, including unrelated actors.
        rejectedCalls++;
    }
}

/// @notice Random call sequences must preserve the fixed mint and each holder's permissions.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract MADTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    MADTokenHandler internal handler;
    MADToken internal token;

    function setUp() public {
        handler = new MADTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.selfTransfer.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.approveInfinite.selector;
        selectors[5] = handler.revoke.selector;
        selectors[6] = handler.transferFrom.selector;
        selectors[7] = handler.rejectOverdraw.selector;
        selectors[8] = handler.rejectOverspend.selector;
        selectors[9] = handler.rejectUnapprovedCaller.selector;
        selectors[10] = handler.rejectZeroRecipient.selector;
        selectors[11] = handler.rejectPrivilegedCall.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyEqualsAllHolderBalances() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), SUPPLY, "constructor supply changed");
        assertEq(sum, SUPPLY, "tokens created, lost, or diverted outside holders");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(handler.outsider()), 0);
    }

    function invariant_balancesMatchOnlyAuthorizedTransfers() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder accounting diverged");
        }
    }

    function invariant_allowancesMatchLatestApprovalAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance exceeded, consumed on failure, or changed for another pair"
                );
            }
            assertEq(token.allowance(owner, handler.outsider()), 0);
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    /// @dev A deterministic sequence pins nonzero delegated moves, full drains, self transfers,
    /// revocation, infinite approval, and each failure probe independently of random selection.
    function test_handlerSequenceExercisesEveryActionAndMovesValue() public {
        handler.transfer(0, 1, 1);
        handler.transferAll(1, 2);
        handler.selfTransfer(2, 2);
        handler.approve(2, 3, 100);
        handler.transferFrom(2, 3, 0, 2);
        handler.approveInfinite(0, 1);
        handler.transferFrom(0, 1, 3, 2);
        handler.revoke(0, 1);
        handler.rejectOverdraw(0, 1, type(uint256).max);
        handler.rejectOverspend(0, 1, 2, 1);
        handler.rejectUnapprovedCaller(3, 0, 1);
        handler.approve(3, 2, 50);
        handler.rejectZeroRecipient(3, 2, 2);
        for (uint256 i; i < 8; ++i) {
            handler.rejectPrivilegedCall(0, 3, i);
        }
        assertGt(handler.directVolume(), 0);
        assertGt(handler.delegatedVolume(), 0);
        assertEq(handler.rejectedCalls(), 12);
        invariant_fixedSupplyEqualsAllHolderBalances();
        invariant_balancesMatchOnlyAuthorizedTransfers();
        invariant_allowancesMatchLatestApprovalAndSuccessfulSpending();
    }
}
