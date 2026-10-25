// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IRepayFirstPayee} from "../src/IRepayFirstPayee.sol";
import {IRepayFirstProvider} from "../src/IRepayFirstProvider.sol";
import {RepayFirstPayee, RepayFirstPayeeFactory} from "../src/RepayFirstPayee.sol";
import {
    MockRegistry,
    MockToken,
    MockCreditor,
    RevertingCreditor,
    GreedyCreditor,
    GasBurningCreditor,
    FullRepaymentLender,
    FullRepaymentCreditor,
    MockAgenticCommerce
} from "./mocks/Mocks.sol";

contract RepayFirstPayeeTest is Test {
    event Swept(address indexed token, uint256 toCreditors, uint256 forwarded);
    event Reserved(address indexed creditor, address indexed token, uint256 amount);

    uint256 constant AGENT = 8835;

    MockRegistry registry;
    MockToken usd;
    RepayFirstPayeeFactory factory;
    RepayFirstPayee payee;
    MockCreditor lenderA;
    MockCreditor lenderB;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    address client = makeAddr("client");
    address evaluator = makeAddr("evaluator");

    function setUp() public {
        registry = new MockRegistry();
        usd = new MockToken();
        factory = new RepayFirstPayeeFactory(address(registry));
        registry.mint(owner, AGENT);
        payee = RepayFirstPayee(factory.deploy(AGENT));
        lenderA = new MockCreditor();
        lenderB = new MockCreditor();
    }

    function _pay(uint256 amount) internal {
        usd.mint(address(payee), amount); // an x402 payment is a plain transfer to the payee
    }

    function _add(address creditor, uint16 bps) internal {
        vm.prank(owner);
        payee.addCreditor(creditor, bps);
    }

    /// @dev A creditor for a loan of `due` from a lender that takes repayment only in full.
    function _addFullOnly(uint256 due, uint16 bps) internal returns (FullRepaymentCreditor c) {
        FullRepaymentLender lender = new FullRepaymentLender(usd);
        lender.open(1, due);
        c = new FullRepaymentCreditor(lender, 1);
        _add(address(c), bps);
    }

    function _reserved(address creditor) internal view returns (uint256) {
        return payee.reserved(creditor, address(usd));
    }

    // ------------------------------------------------------------- factory and views

    function test_factory_payeeOfIsTheDeployedAddress_andKnownBeforehand() public {
        address predicted = factory.payeeOf(42);
        assertEq(predicted.code.length, 0);
        registry.mint(owner, 42);
        assertEq(factory.deploy(42), predicted);
        assertEq(factory.payeeOf(AGENT), address(payee));
        vm.expectRevert(abi.encodeWithSelector(RepayFirstPayeeFactory.AlreadyDeployed.selector, predicted));
        factory.deploy(42);
    }

    function test_views() public view {
        assertEq(payee.identityRegistry(), address(registry));
        assertEq(payee.agentId(), AGENT);
        assertEq(payee.beneficiary(), owner);
        assertEq(payee.creditors().length, 0);
        assertTrue(payee.supportsInterface(type(IRepayFirstPayee).interfaceId));
        assertTrue(payee.supportsInterface(type(IRepayFirstProvider).interfaceId));
        assertTrue(payee.supportsInterface(0x01ffc9a7));
        assertFalse(payee.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- sweep

    function test_sweep_noCreditors_forwardsEverything() public {
        _pay(100e6);
        vm.expectEmit(true, false, false, true);
        emit Swept(address(usd), 0, 100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6);
        assertEq(usd.balanceOf(owner), 100e6);
    }

    function test_sweep_paysWhatIsOwedFirst_thenForwardsTheRest() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        _pay(100e6);
        vm.prank(stranger); // anyone may sweep
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 70e6);
        assertEq(usd.balanceOf(address(lenderA)), 30e6);
        assertEq(usd.balanceOf(owner), 70e6);
        assertEq(lenderA.owed(AGENT), 0);
    }

    function test_sweep_capsEachCreditorAtItsShareOfTheSweep() public {
        _add(address(lenderA), 2_000); // 20%
        lenderA.setOwed(AGENT, 50e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 20e6);
        assertEq(usd.balanceOf(owner), 80e6);
        assertEq(lenderA.owed(AGENT), 30e6);
    }

    function test_sweep_paysTheSeniorCreditorFirst() public {
        _add(address(lenderA), 10_000);
        _add(address(lenderB), 10_000);
        lenderA.setOwed(AGENT, 60e6);
        lenderB.setOwed(AGENT, 60e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 60e6);
        assertEq(usd.balanceOf(address(lenderB)), 40e6);
        assertEq(usd.balanceOf(owner), 0);
    }

    function test_sweep_creditorTakingLessThanOffered_keepsTheRestInReserve_andAllowanceReset() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 50e6);
        lenderA.setTakeBps(5_000); // applies only half of what it is given
        _pay(100e6);
        vm.expectEmit(true, true, false, true, address(payee));
        emit Reserved(address(lenderA), address(usd), 25e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 25e6);
        assertEq(forwarded, 50e6);
        assertEq(_reserved(address(lenderA)), 25e6); // still owed 25e6: kept for it, not forwarded
        assertEq(usd.balanceOf(address(payee)), 25e6);
        assertEq(usd.allowance(address(payee), address(lenderA)), 0);
    }

    // ------------------------------------------------------------- reserves

    /// @dev ted0x's case on Ethereum Magicians: 100 due to a lender that takes repayment only in full, ten sweeps of 10,
    ///      then one of 100. Each small sweep used to reach the owner while the whole loan stayed due.
    function test_sweep_aLenderTakingOnlyFullRepayment_isRepaidOnceItsReserveCoversWhatIsDue() public {
        FullRepaymentCreditor c = _addFullOnly(100e6, 10_000);
        FullRepaymentLender lender = c.lender();
        for (uint256 i = 1; i <= 9; ++i) {
            _pay(10e6);
            vm.expectEmit(true, true, false, true, address(payee));
            emit Reserved(address(c), address(usd), i * 10e6);
            (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
            assertEq(toCreditors, 0); // the lender refuses a part payment
            assertEq(forwarded, 0); // and none of it reaches the owner
            assertEq(_reserved(address(c)), i * 10e6);
        }
        assertEq(lender.amountDue(1), 100e6);

        _pay(10e6); // the tenth sweep of 10: the reserve now covers what is due
        vm.expectEmit(true, true, false, true, address(payee));
        emit Reserved(address(c), address(usd), 0);
        (uint256 paid, uint256 fwd) = payee.sweep(address(usd));
        assertEq(paid, 100e6);
        assertEq(fwd, 0);
        assertEq(lender.amountDue(1), 0);
        assertEq(usd.balanceOf(address(lender)), 100e6);
        assertEq(usd.balanceOf(owner), 0);
        assertEq(usd.allowance(address(payee), address(c)), 0);

        _pay(100e6); // then one of 100, with nothing owed
        (paid, fwd) = payee.sweep(address(usd));
        assertEq(paid, 0);
        assertEq(fwd, 100e6);
        assertEq(usd.balanceOf(owner), 100e6);
        assertEq(usd.balanceOf(address(payee)), 0);
    }

    function test_sweep_releasesAReserve_onceTheLoanIsRepaidFromElsewhere() public {
        FullRepaymentCreditor c = _addFullOnly(100e6, 10_000);
        FullRepaymentLender lender = c.lender();
        _pay(90e6);
        payee.sweep(address(usd));
        assertEq(_reserved(address(c)), 90e6);

        usd.mint(owner, 100e6); // the owner repays the loan from another wallet
        vm.startPrank(owner);
        usd.approve(address(lender), 100e6);
        lender.repay(1, 100e6);
        vm.stopPrank();

        _pay(10e6);
        vm.expectEmit(true, true, false, true, address(payee));
        emit Reserved(address(c), address(usd), 0);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6); // the 90e6 released and the 10e6 that arrived
        assertEq(usd.balanceOf(owner), 100e6);
        assertEq(usd.balanceOf(address(payee)), 0);
    }

    function test_sweep_onADefault_aCreditorReportingNothingOwedReleasesItsReserve() public {
        FullRepaymentCreditor c = _addFullOnly(100e6, 10_000);
        _pay(90e6);
        payee.sweep(address(usd));
        c.lender().markDefault(1); // the loan closes unpaid; the lender reports nothing due
        assertFalse(c.hasClaim(AGENT));

        _pay(10e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6);
        assertEq(_reserved(address(c)), 0);
        vm.prank(owner);
        payee.removeCreditor(address(c)); // no claim left
    }

    function test_sweep_aCreditorWhoseAmountOwedFails_isOwedNothing_soItsReserveIsReleased() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 50e6);
        lenderA.setTakeBps(0); // takes nothing yet
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 50e6);
        assertEq(_reserved(address(lenderA)), 50e6);

        lenderA.setDown(true);
        vm.expectEmit(true, true, false, true, address(payee));
        emit Reserved(address(lenderA), address(usd), 0);
        (toCreditors, forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 50e6);
        assertEq(usd.balanceOf(owner), 100e6);
    }

    function test_removeCreditor_releasesItsReserve_andACreditorAddedAgainStartsWithNone() public {
        FullRepaymentCreditor c = _addFullOnly(100e6, 10_000);
        _pay(90e6);
        payee.sweep(address(usd));
        assertEq(_reserved(address(c)), 90e6);

        vm.prank(address(c));
        payee.removeCreditor(address(c)); // a creditor may leave at any time; its reserve goes with its place
        assertEq(_reserved(address(c)), 0);
        _pay(10e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6);

        _add(address(c), 10_000); // added again, still owed 100e6
        assertEq(_reserved(address(c)), 0);
        _pay(10e6);
        payee.sweep(address(usd));
        assertEq(_reserved(address(c)), 10e6); // what it is offered now, not the 90e6 it gave up
    }

    function testFuzz_sweep_reservesAndPaymentsAddUp(
        uint64[4] memory payments,
        uint64 due,
        uint64 owedB,
        uint16 bpsFull,
        uint16 bpsB
    ) public {
        due = uint64(bound(due, 1, type(uint64).max));
        bpsFull = uint16(bound(bpsFull, 1, 10_000));
        bpsB = uint16(bound(bpsB, 1, 10_000));
        FullRepaymentCreditor c = _addFullOnly(due, bpsFull); // senior, takes only the whole amount due
        _add(address(lenderB), bpsB); // junior, takes whatever it is given up to what it is owed
        lenderB.setOwed(AGENT, owedB);
        FullRepaymentLender lender = c.lender();

        uint256 paidIn;
        uint256 toCreditors;
        uint256 forwarded;
        uint256 setAside; // the senior's share of each sweep, up to what it is due: paid to it or held for it
        for (uint256 i; i < 4; ++i) {
            _pay(payments[i]);
            paidIn += payments[i];
            setAside += uint256(payments[i]) * bpsFull / 10_000;
            if (setAside > due) setAside = due;
            (uint256 t, uint256 f) = payee.sweep(address(usd));
            toCreditors += t;
            forwarded += f;
            assertEq(usd.balanceOf(address(lender)) + _reserved(address(c)), setAside);
            assertEq(usd.balanceOf(address(payee)), _reserved(address(c)) + _reserved(address(lenderB)));
            assertLe(_reserved(address(c)), lender.amountDue(1));
            assertEq(_reserved(address(lenderB)), 0);
            assertEq(usd.allowance(address(payee), address(c)), 0);
        }
        assertEq(toCreditors + forwarded + usd.balanceOf(address(payee)), paidIn);
        assertEq(toCreditors, usd.balanceOf(address(lender)) + usd.balanceOf(address(lenderB)));
        assertTrue(usd.balanceOf(address(lender)) == 0 || usd.balanceOf(address(lender)) == due); // never a part
        assertEq(usd.balanceOf(owner), forwarded);
    }

    function test_sweep_skipsAFailingCreditor() public {
        RevertingCreditor bad = new RevertingCreditor();
        _add(address(bad), 10_000);
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 10e6);
        assertEq(forwarded, 90e6);
    }

    function test_sweep_survivesACreditorThatBurnsItsGas() public {
        GasBurningCreditor burner = new GasBurningCreditor(); // owed 1e6
        _add(address(burner), 10_000);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep{gas: 2_000_000}(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 99e6);
        assertEq(_reserved(address(burner)), 1e6); // what it was offered stays in reserve for it
        assertEq(usd.allowance(address(payee), address(burner)), 0);
    }

    function test_sweep_aCreditorCannotTakeMoreThanItIsGiven() public {
        GreedyCreditor greedy = new GreedyCreditor();
        _add(address(greedy), 3_000);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0); // its pull of give + 1 failed against the allowance
        assertEq(forwarded, 70e6);
        assertEq(_reserved(address(greedy)), 30e6); // its share stays in the payee, untaken
        assertEq(usd.balanceOf(address(greedy)), 0);
    }

    function test_sweep_afterTheIdentityIsBurned_stillPaysCreditors_andKeepsTheRest() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        vm.prank(owner);
        registry.burn(AGENT);
        assertEq(payee.beneficiary(), address(0)); // no owner to read, none set

        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 0);
        assertEq(usd.balanceOf(address(lenderA)), 30e6);
        assertEq(usd.balanceOf(address(payee)), 70e6); // kept, not lost to the zero address
    }

    function test_sweep_emptyBalance_isANoOp() public {
        (uint256 a, uint256 b) = payee.sweep(address(usd));
        assertEq(a + b, 0);
    }

    function testFuzz_sweep_conservesTheBalance(uint96 paid, uint96 owedA, uint96 owedB, uint16 bpsA, uint16 bpsB)
        public
    {
        bpsA = uint16(bound(bpsA, 1, 10_000));
        bpsB = uint16(bound(bpsB, 1, 10_000));
        _add(address(lenderA), bpsA);
        _add(address(lenderB), bpsB);
        lenderA.setOwed(AGENT, owedA);
        lenderB.setOwed(AGENT, owedB);
        _pay(paid);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));

        uint256 tookA = usd.balanceOf(address(lenderA));
        uint256 tookB = usd.balanceOf(address(lenderB));
        assertEq(toCreditors + forwarded, paid);
        assertEq(tookA + tookB, toCreditors);
        assertEq(usd.balanceOf(owner), forwarded);
        assertLe(tookA, owedA);
        assertLe(tookA, uint256(paid) * bpsA / 10_000);
        assertLe(tookB, owedB);
        assertLe(tookB, uint256(paid) * bpsB / 10_000);
        assertEq(usd.balanceOf(address(payee)), 0);
    }

    // ------------------------------------------------------------- configuration

    function test_onlyTheOwnerConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.addCreditor(address(lenderA), 10_000);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.setBeneficiary(stranger);
        vm.stopPrank();
    }

    function test_addCreditor_rejectsBadInput() public {
        vm.startPrank(owner);
        vm.expectRevert(RepayFirstPayee.BadShare.selector);
        payee.addCreditor(address(lenderA), 0);
        vm.expectRevert(RepayFirstPayee.BadShare.selector);
        payee.addCreditor(address(lenderA), 10_001);
        vm.expectRevert(RepayFirstPayee.BadCreditor.selector);
        payee.addCreditor(address(0), 1);
        payee.addCreditor(address(lenderA), 1);
        vm.expectRevert(RepayFirstPayee.BadCreditor.selector);
        payee.addCreditor(address(lenderA), 1);
        vm.stopPrank();
    }

    function test_setBeneficiary_redirectsOnlyWhatIsLeft() public {
        address wallet = makeAddr("wallet");
        vm.prank(owner);
        payee.setBeneficiary(wallet);
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 10e6);
        assertEq(usd.balanceOf(wallet), 90e6);
    }

    function test_setBeneficiary_lapsesWhenTheIdentityIsSold() public {
        address sellersWallet = makeAddr("sellersWallet");
        vm.prank(owner);
        payee.setBeneficiary(sellersWallet); // set just before selling
        vm.prank(owner);
        registry.transfer(AGENT, buyer);

        assertEq(payee.beneficiary(), buyer);
        _pay(100e6); // revenue earned after the sale
        vm.prank(stranger); // anyone may sweep, the seller included
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(buyer), 100e6);
        assertEq(usd.balanceOf(sellersWallet), 0);
    }

    function test_setBeneficiary_appliesAgainIfTheSameOwnerHoldsTheIdentity() public {
        address wallet = makeAddr("wallet");
        vm.prank(owner);
        payee.setBeneficiary(wallet);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        vm.prank(buyer);
        registry.transfer(AGENT, owner); // back to the owner who chose it
        assertEq(payee.beneficiary(), wallet);
    }

    function test_removeCreditor_ownerCannotDropAnOwedCreditor_canOnceRepaid() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(lenderA));

        _pay(10e6);
        payee.sweep(address(usd)); // repaid from revenue
        vm.prank(owner);
        payee.removeCreditor(address(lenderA));
        assertEq(payee.creditors().length, 0);
        assertEq(payee.maxShareBps(address(lenderA)), 0);
    }

    function test_removeCreditor_aFailingClaimCheckCountsAsAClaim() public {
        RevertingCreditor bad = new RevertingCreditor();
        _add(address(bad), 10_000);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(bad));
    }

    function test_removeCreditor_theCreditorMayLeaveAnytime_andOrderIsKept() public {
        MockCreditor lenderC = new MockCreditor();
        _add(address(lenderA), 10_000);
        _add(address(lenderB), 10_000);
        _add(address(lenderC), 10_000);
        lenderB.setOwed(AGENT, 1);
        vm.prank(address(lenderB));
        payee.removeCreditor(address(lenderB));
        address[] memory cs = payee.creditors();
        assertEq(cs.length, 2);
        assertEq(cs[0], address(lenderA));
        assertEq(cs[1], address(lenderC));
    }

    function test_afterATransfer_theNewOwnerControls_butCannotDropAnOwedCreditor() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);

        assertEq(payee.beneficiary(), buyer);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.addCreditor(address(lenderB), 10_000);
        vm.prank(buyer);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(lenderA));
    }

    // ------------------------------------------------------------- ERC-8183 provider

    /// @dev A job whose provider is the payee, funded with `budget` once the provider has proposed it through the payee.
    function _fundedJob(MockAgenticCommerce commerce, address actor, uint256 budget) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = commerce.createJob(address(payee), evaluator);
        vm.prank(actor);
        payee.setJobBudget(address(commerce), jobId, budget, "");
        usd.mint(client, budget);
        vm.startPrank(client);
        usd.approve(address(commerce), budget);
        commerce.fund(jobId, budget, "");
        vm.stopPrank();
    }

    /// @dev Revinand's case on Ethereum Magicians: ERC-8183 takes the submission only from the provider, so a job whose
    ///      provider was the payee could not reach Submitted. Create, fund, submit, complete, then sweep.
    function test_provider_aJobWithThePayeeAsProvider_isSubmittedAndPaid_andTheSweepRepaysFirst() public {
        MockAgenticCommerce commerce = new MockAgenticCommerce(usd);
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        uint256 jobId = _fundedJob(commerce, owner, 50e6);
        assertEq(uint256(commerce.statusOf(jobId)), uint256(MockAgenticCommerce.Status.Funded));

        vm.prank(owner); // the owner's own wallet is not the job's provider
        vm.expectRevert(bytes("unauthorized"));
        commerce.submit(jobId, keccak256("work"), "");

        vm.prank(owner);
        payee.submitJob(address(commerce), jobId, keccak256("work"), "");
        assertEq(uint256(commerce.statusOf(jobId)), uint256(MockAgenticCommerce.Status.Submitted));

        vm.prank(evaluator);
        commerce.complete(jobId, bytes32(0), "");
        assertEq(usd.balanceOf(address(payee)), 50e6); // the job pays its provider: the payee

        vm.prank(stranger);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 20e6);
        assertEq(usd.balanceOf(address(lenderA)), 30e6);
        assertEq(usd.balanceOf(owner), 20e6);
    }

    function test_provider_theOperatorActsForTheOwner_untilTheIdentityIsSold() public {
        MockAgenticCommerce commerce = new MockAgenticCommerce(usd);
        address agentKey = makeAddr("agentKey");
        vm.prank(owner);
        payee.setOperator(agentKey);
        assertEq(payee.operator(), agentKey);

        uint256 jobId = _fundedJob(commerce, agentKey, 10e6);
        vm.prank(agentKey);
        payee.submitJob(address(commerce), jobId, keccak256("work"), "");
        assertEq(uint256(commerce.statusOf(jobId)), uint256(MockAgenticCommerce.Status.Submitted));

        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        assertEq(payee.operator(), address(0)); // the seller's operator lapses with the sale
        vm.prank(client);
        uint256 next = commerce.createJob(address(payee), evaluator);
        vm.prank(agentKey);
        vm.expectRevert(RepayFirstPayee.NotOperator.selector);
        payee.setJobBudget(address(commerce), next, 10e6, "");
        vm.prank(buyer);
        payee.setJobBudget(address(commerce), next, 10e6, "");
    }

    function test_provider_onlyTheOwnerOrTheOperator() public {
        MockAgenticCommerce commerce = new MockAgenticCommerce(usd);
        uint256 jobId = _fundedJob(commerce, owner, 10e6);
        vm.startPrank(stranger);
        vm.expectRevert(RepayFirstPayee.NotOperator.selector);
        payee.setJobBudget(address(commerce), jobId, 1, "");
        vm.expectRevert(RepayFirstPayee.NotOperator.selector);
        payee.submitJob(address(commerce), jobId, keccak256("work"), "");
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.setOperator(stranger);
        vm.stopPrank();

        vm.prank(owner);
        registry.burn(AGENT); // no owner to read: nobody acts for the agent
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.NotOperator.selector);
        payee.submitJob(address(commerce), jobId, keccak256("work"), "");
    }

    /// @dev The two calls are the only ones the payee makes for its owner, so naming a token, or an address with no
    ///      code, as `commerce` moves nothing: a token has neither function.
    function test_provider_theCallsCannotMoveThePayeesBalance() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        _pay(100e6);
        vm.startPrank(owner);
        vm.expectRevert();
        payee.submitJob(address(usd), 1, bytes32(uint256(uint160(owner))), "");
        vm.expectRevert();
        payee.setJobBudget(address(usd), uint256(uint160(owner)), 100e6, "");
        vm.expectRevert();
        payee.submitJob(stranger, 1, bytes32(0), "");
        vm.stopPrank();
        assertEq(usd.balanceOf(address(payee)), 100e6);
        assertEq(usd.balanceOf(owner), 0);

        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 70e6);
    }

    function test_maxCreditors() public {
        vm.startPrank(owner);
        for (uint256 i; i < 8; ++i) {
            payee.addCreditor(address(new MockCreditor()), 1);
        }
        address ninth = address(new MockCreditor());
        vm.expectRevert(RepayFirstPayee.TooManyCreditors.selector);
        payee.addCreditor(ninth, 1);
        vm.stopPrank();
    }
}
