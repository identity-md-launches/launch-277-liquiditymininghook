// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {FARMX} from "../src/FARMX.sol";

contract FARMXTest is Test {
    FARMX token;
    address alice = address(0xA11CE);

    function setUp() public {
        token = new FARMX();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Farm");
        assertEq(token.symbol(), "FARMX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice), token.totalSupply());
    }

    function test_allowanceAndFailures() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 7 ether);
        assertEq(token.allowance(address(this), alice), 3 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(this), alice, 4 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(this), 8 ether);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_noPrivilegedSelectorsEvenForDeployer() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_refusesETHAndEscapeOpcodes() public {
        vm.deal(address(this), 1);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
