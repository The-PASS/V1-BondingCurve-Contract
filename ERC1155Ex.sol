// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// extended ERC1155 which records all tokens IDs owned by a user
contract ERC1155Ex is ERC1155 {
    using EnumerableSet for EnumerableSet.UintSet;
    
    address public curve;
    uint256 public totalSupply;         // total supply of erc1155 tokens
    uint256 public tokenId;
    mapping(address => EnumerableSet.UintSet) private userTokenIds;   // record all users' token IDs
    
    constructor () ERC1155("") {
        curve = msg.sender;
    }
    
    // mint a batch of erc1155 tokens to address(_to).
    function mint(address _to, uint256 _balance) public returns(uint256) {
        require(msg.sender == curve, "NFT1155: Minter is not the CURVE");   
        _mint(_to, tokenId, _balance, "");
        tokenId += 1;
        totalSupply += _balance;
        userTokenIds[_to].add(tokenId);
        return tokenId;
    }
    
    /**@dev Destroy erc1155 tokens owned by address(_to)
    *ID: token Id
    *_balance: number of erc1155 tokens destroyed
    */
    function burn(address _to, uint256 _tokenId, uint256 _balance) public {
        require(msg.sender == curve, "NFT1155: Minter is not the CURVE");
        _burn(_to, _tokenId, _balance);
        totalSupply -= _balance;
        if (balanceOf(_to, _tokenId) == 0) {
            userTokenIds[_to].remove(tokenId);
        }
    }

    // Get the total number of ERC1155 token IDs owned by a user
    function getUserTokenIdNumber(address _userAddr) public view returns(uint256) {
        return userTokenIds[_userAddr].length();
    }
    
    // Get token IDs by user address and index number
    function getUserTokenId(address _userAddr, uint256 _index) public view returns(uint256) {
        return userTokenIds[_userAddr].at(_index);
    }
}
