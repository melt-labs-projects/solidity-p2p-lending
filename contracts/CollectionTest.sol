// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract CollectionTest is ERC721{
    constructor() ERC721("TestC", "Ctest") {}

    function safeMint(address _to, uint _tokenId) public {
        _safeMint(_to, _tokenId);
    }
}