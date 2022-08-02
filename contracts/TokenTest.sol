// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenTest is ERC20{

    constructor() ERC20("Test", "TST"){

    }


    function mint(address _to, uint256 _amount) external {
        _mint(_to,_amount);
    }

    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }
}