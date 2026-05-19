// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArceloWithdraw {
    function deposit(address token, uint256 amount) external payable;
    function withdraw(address token, uint256 amount) external;
}

contract ReentrantReceiver {
    IArceloWithdraw public target;
    bool public attack;

    receive() external payable {
        if (attack) {
            attack = false;
            target.withdraw(address(0), 1);
        }
    }

    function prepare(IArceloWithdraw target_) external {
        target = target_;
    }

    function setAttack(bool attack_) external {
        attack = attack_;
    }

    function withdraw(address token, uint256 amount) external {
        target.withdraw(token, amount);
    }

    function depositNative(uint256 amount) external payable {
        target.deposit{value: msg.value}(address(0), amount);
    }
}
