// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AdversarialToken is ERC20 {
    uint256 public taxBps;
    bool public failTransfers;
    address public target;
    bytes public payload;
    bool public attackSucceeded;
    bytes public attackResult;

    constructor() ERC20("Adversarial", "ADV") {
        _mint(msg.sender, type(uint256).max);
    }

    function setTax(uint256 bps) external {
        require(bps <= 10000);
        taxBps = bps;
    }

    function setFailure(bool fail) external {
        failTransfers = fail;
    }

    function setAttack(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            if (target != address(0)) (attackSucceeded, attackResult) = target.call(payload);
            uint256 fee = amount / 10000 * taxBps;
            if (fee != 0) super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
