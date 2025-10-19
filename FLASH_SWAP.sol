// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

interface CALLER {
    function callBack(uint256 amount, uint256 fee, string memory data) external returns (bool);
}

interface ERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract FLASH_SWAP {
    address public ERC20Address;
    uint256 public FEE_PER_THOUSAND;

    constructor(address erc20_addr, uint256 fee) {
        ERC20Address = erc20_addr;
        FEE_PER_THOUSAND = fee;
    }

    function flashSwap(uint256 amount, string memory data) external returns (bool) {

        uint256 usedAmount = ERC20(ERC20Address).balanceOf(address(this));
        require(usedAmount >= amount, "Not enough money");
        require(ERC20(ERC20Address).transfer(msg.sender, amount), "Transfer error");
        uint256 Fee = amount * FEE_PER_THOUSAND / 10;

        CALLER(msg.sender).callBack(amount, Fee, data);
        
        uint256 curAmount = ERC20(ERC20Address).balanceOf(address(this));
        require(curAmount >= usedAmount + Fee, "Do not give back enough money");
        return true;
    }
}
