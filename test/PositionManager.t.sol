// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {AllowanceTransferMock} from "./mocks/AllowanceTransferMock.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract PositionManagerTest is HookTestBase {
    using StateLibrary for IPoolManager;
    PositionManager internal posm;
    AllowanceTransferMock internal permit2;

    function setUp() public override {
        super.setUp();
        permit2 = new AllowanceTransferMock();
        posm = new PositionManager(
            manager,
            IAllowanceTransfer(address(permit2)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(posm), type(uint160).max, type(uint48).max);
    }

    function _positionKey(uint256 tokenId) internal view returns (bytes32) {
        return hook.positionKey(address(posm), LOWER, UPPER, bytes32(tokenId));
    }

    function _mintPosition(bytes memory data) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        _act(
            Actions.MINT_POSITION,
            abi.encode(key, LOWER, UPPER, L, type(uint128).max, type(uint128).max, address(this), data),
            2 ether
        );
    }

    function _act(uint256 action, bytes memory params, uint256 value) internal {
        bytes[] memory list = new bytes[](4);
        list[0] = params;
        list[1] = abi.encode(key.currency0);
        list[2] = abi.encode(key.currency1);
        list[3] = abi.encode(key.currency0, address(this));
        bytes memory actions = abi.encodePacked(
            uint8(action), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.SWEEP)
        );
        posm.modifyLiquidities{value: value}(abi.encode(actions, list), block.timestamp);
    }

    function test_realPositionManagerMintCollectDecreaseAndBurn() public {
        uint256 tokenId = _mintPosition(abi.encode(alice));
        bytes32 pk = _positionKey(tokenId);
        assertEq(hook.staked(id, pk), L);
        assertEq(manager.getPositionLiquidity(id, pk), L);
        assertEq(posm.ownerOf(tokenId), address(this));
        _fund(D * 1 ether);
        _swap(true, -0.1 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 beforeBalance = address(this).balance;
        _act(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")), 0
        );
        assertGt(address(this).balance, beforeBalance);
        assertEq(hook.staked(id, pk), L);
        _act(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, uint256(0), type(uint128).max, type(uint128).max, bytes("")),
            0
        );
        assertEq(hook.staked(id, pk), L);
        _act(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, L / 2, uint128(0), uint128(0), bytes("")), 0);
        assertEq(hook.staked(id, pk), L / 2);
        assertEq(manager.getPositionLiquidity(id, pk), L / 2);
        vm.warp(block.timestamp + 1 days);
        _act(Actions.BURN_POSITION, abi.encode(tokenId, uint128(0), uint128(0), bytes("")), 0);
        assertEq(hook.totalStaked(id), 0);
        assertEq(manager.getPositionLiquidity(id, pk), 0);
        assertEq(_claim(alice, pk), 2 days * 1 ether);
        vm.warp(block.timestamp + D);
        assertEq(hook.idle(id), 28 days * 1 ether);
        _assertCoverage(0);
    }

    function test_transferringNftDoesNotTransferBeneficiaryAndNewOwnerCanExit() public {
        uint256 tokenId = _mintPosition(abi.encode(alice));
        bytes32 pk = _positionKey(tokenId);
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 1 days);
        posm.transferFrom(address(this), bob, tokenId);
        vm.prank(bob);
        vm.expectRevert(LiquidityMiningHook.OnlyBeneficiary.selector);
        hook.claim(key, pk);
        // Bob may manage the NFT but cannot change its reward recipient through hookData.
        vm.startPrank(bob);
        _act(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, L / 2, uint128(0), uint128(0), abi.encode(bob)), 0
        );
        _act(Actions.BURN_POSITION, abi.encode(tokenId, uint128(0), uint128(0), abi.encode(bob)), 0);
        vm.stopPrank();
        assertEq(hook.beneficiaryOf(id, pk), alice);
        assertEq(hook.staked(id, pk), 0);
        assertEq(_claim(alice, pk), 1 days * 1 ether);
    }

    function test_unapprovedUserCannotModifySharedPositionManagerKey() public {
        uint256 tokenId = _mintPosition(abi.encode(alice));
        bytes32 pk = _positionKey(tokenId);
        vm.startPrank(bob);
        vm.expectPartialRevert(IPositionManager.NotApproved.selector);
        _act(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, L, uint128(0), uint128(0), abi.encode(bob)), 0);
        vm.expectPartialRevert(IPositionManager.NotApproved.selector);
        _act(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, L, type(uint128).max, type(uint128).max, abi.encode(bob)),
            0
        );
        vm.stopPrank();
        assertEq(hook.staked(id, pk), L);
        assertEq(hook.beneficiaryOf(id, pk), alice);
    }

    function test_lateEnrollmentAndBurnEmptyNft() public {
        uint256 tokenId = _mintPosition("");
        bytes32 pk = _positionKey(tokenId);
        assertEq(hook.staked(id, pk), 0);
        _act(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, L, type(uint128).max, type(uint128).max, abi.encode(alice)),
            2 ether
        );
        assertEq(hook.staked(id, pk), L);
        _act(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, L, uint128(0), uint128(0), bytes("")), 0);
        assertEq(hook.staked(id, pk), L);
        _act(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, L, uint128(0), uint128(0), bytes("")), 0);
        assertEq(hook.staked(id, pk), 0);
        _act(Actions.BURN_POSITION, abi.encode(tokenId, uint128(0), uint128(0), bytes("")), 0);
        assertEq(hook.totalStaked(id), 0);
        assertEq(hook.beneficiaryOf(id, pk), alice);
    }
}
