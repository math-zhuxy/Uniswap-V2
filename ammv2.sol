// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract AMMV2 {
    address public poolOwner;
    mapping(address => uint256) public userLpToken;
    uint256 public lpTokenTotalSupply;

    address public tokenAAddress;
    address public tokenBAddress;
    uint256 public poolTokenANum;
    uint256 public poolTokenBNum;
    
    // 手续费率 (千分之三)
    uint256 public constant FEE_RATE = 3;
    uint256 public constant FEE_DENOMINATOR = 1000;
    
    // 最小流动性锁定
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    event AddLiquidity(address indexed user, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event RemoveLiquidity(address indexed user, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);
    
    modifier onlyPoolOwner() {
        require(msg.sender == poolOwner, "Only pool owner can call this function");
        _;
    }
    
    constructor(address _tokenA, address _tokenB) {
        poolOwner = msg.sender;
        tokenAAddress = _tokenA;
        tokenBAddress = _tokenB;
        poolTokenANum = 0;
        poolTokenBNum = 0;
        lpTokenTotalSupply = 0;
    }
    
    // 添加流动性
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 lpTokens) {
        require(amountA > 0 && amountB > 0, "Invalid amounts");
        
        // 转入代币
        require(IERC20(tokenAAddress).transferFrom(msg.sender, address(this), amountA), "Transfer A failed");
        require(IERC20(tokenBAddress).transferFrom(msg.sender, address(this), amountB), "Transfer B failed");
        
        if (lpTokenTotalSupply == 0) {
            // 首次添加流动性
            lpTokens = sqrt(amountA * amountB);
            require(lpTokens > MINIMUM_LIQUIDITY, "Insufficient liquidity");
            
            // 锁定最小流动性
            lpTokenTotalSupply = MINIMUM_LIQUIDITY;
            userLpToken[address(0)] = MINIMUM_LIQUIDITY;
            lpTokens -= MINIMUM_LIQUIDITY;
        } else {
            // 后续添加流动性，按比例计算
            uint256 lpTokensA = (amountA * lpTokenTotalSupply) / poolTokenANum;
            uint256 lpTokensB = (amountB * lpTokenTotalSupply) / poolTokenBNum;
            lpTokens = lpTokensA < lpTokensB ? lpTokensA : lpTokensB;
        }
        
        require(lpTokens > 0, "Insufficient LP tokens");
        
        // 更新状态
        poolTokenANum += amountA;
        poolTokenBNum += amountB;
        lpTokenTotalSupply += lpTokens;
        userLpToken[msg.sender] += lpTokens;
        
        emit AddLiquidity(msg.sender, amountA, amountB, lpTokens);
    }
    
    // 移除流动性
    function removeLiquidity(uint256 lpTokens) external returns (uint256 amountA, uint256 amountB) {
        require(lpTokens > 0, "Invalid LP tokens");
        require(userLpToken[msg.sender] >= lpTokens, "Insufficient LP tokens");
        
        // 计算可提取的代币数量
        amountA = (lpTokens * poolTokenANum) / lpTokenTotalSupply;
        amountB = (lpTokens * poolTokenBNum) / lpTokenTotalSupply;
        
        require(amountA > 0 && amountB > 0, "Insufficient liquidity");
        
        // 更新状态
        userLpToken[msg.sender] -= lpTokens;
        lpTokenTotalSupply -= lpTokens;
        poolTokenANum -= amountA;
        poolTokenBNum -= amountB;
        
        // 转出代币
        require(IERC20(tokenAAddress).transfer(msg.sender, amountA), "Transfer A failed");
        require(IERC20(tokenBAddress).transfer(msg.sender, amountB), "Transfer B failed");
        
        emit RemoveLiquidity(msg.sender, amountA, amountB, lpTokens);
    }
    
    // 代币兑换 - A换B
    function swapAForB(uint256 amountAIn) external returns (uint256 amountBOut) {
        require(amountAIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        // 计算手续费后的输入金额
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        
        // 根据 x*y=k 模型计算输出金额
        amountBOut = (poolTokenBNum * amountAInWithFee) / (poolTokenANum + amountAInWithFee);
        
        require(amountBOut > 0, "Insufficient output amount");
        require(amountBOut < poolTokenBNum, "Insufficient liquidity");
        
        // 转入代币A
        require(IERC20(tokenAAddress).transferFrom(msg.sender, address(this), amountAIn), "Transfer A failed");
        
        // 转出代币B
        require(IERC20(tokenBAddress).transfer(msg.sender, amountBOut), "Transfer B failed");
        
        // 更新池子状态
        poolTokenANum += amountAIn;
        poolTokenBNum -= amountBOut;
        
        emit Swap(msg.sender, tokenAAddress, amountAIn, tokenBAddress, amountBOut);
    }
    
    // 代币兑换 - B换A
    function swapBForA(uint256 amountBIn) external returns (uint256 amountAOut) {
        require(amountBIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        // 计算手续费后的输入金额
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        
        // 根据 x*y=k 模型计算输出金额
        amountAOut = (poolTokenANum * amountBInWithFee) / (poolTokenBNum + amountBInWithFee);
        
        require(amountAOut > 0, "Insufficient output amount");
        require(amountAOut < poolTokenANum, "Insufficient liquidity");
        
        // 转入代币B
        require(IERC20(tokenBAddress).transferFrom(msg.sender, address(this), amountBIn), "Transfer B failed");
        
        // 转出代币A
        require(IERC20(tokenAAddress).transfer(msg.sender, amountAOut), "Transfer A failed");
        
        // 更新池子状态
        poolTokenBNum += amountBIn;
        poolTokenANum -= amountAOut;
        
        emit Swap(msg.sender, tokenBAddress, amountBIn, tokenAAddress, amountAOut);
    }
    
    // 获取兑换报价 - A换B
    function getAmountBOut(uint256 amountAIn) external view returns (uint256 amountBOut) {
        require(amountAIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        amountBOut = (poolTokenBNum * amountAInWithFee) / (poolTokenANum + amountAInWithFee);
    }
    
    // 获取兑换报价 - B换A
    function getAmountAOut(uint256 amountBIn) external view returns (uint256 amountAOut) {
        require(amountBIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        amountAOut = (poolTokenANum * amountBInWithFee) / (poolTokenBNum + amountBInWithFee);
    }
    
    // 获取当前汇率
    function getExchangeRate() external view returns (uint256 rateAToB, uint256 rateBToA) {
        if (poolTokenANum > 0 && poolTokenBNum > 0) {
            rateAToB = (poolTokenBNum * 1e18) / poolTokenANum;
            rateBToA = (poolTokenANum * 1e18) / poolTokenBNum;
        }
    }
    
    // 获取用户LP代币余额
    function getUserLPBalance(address user) external view returns (uint256) {
        return userLpToken[user];
    }
    
    // 获取池子信息
    function getPoolInfo() external view returns (
        uint256 tokenABalance,
        uint256 tokenBBalance,
        uint256 totalLPSupply,
        uint256 k
    ) {
        tokenABalance = poolTokenANum;
        tokenBBalance = poolTokenBNum;
        totalLPSupply = lpTokenTotalSupply;
        k = poolTokenANum * poolTokenBNum;
    }
    
    // Babylonian method
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    // 紧急提取函数
    function emergencyWithdraw() external onlyPoolOwner {
        uint256 balanceA = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 balanceB = IERC20(tokenBAddress).balanceOf(address(this));
        
        if (balanceA > 0) {
            IERC20(tokenAAddress).transfer(poolOwner, balanceA);
        }
        if (balanceB > 0) {
            IERC20(tokenBAddress).transfer(poolOwner, balanceB);
        }
    }
    
    // 转移池子所有权
    function transferOwnership(address newOwner) external onlyPoolOwner {
        require(newOwner != address(0), "Invalid address");
        poolOwner = newOwner;
    }
}
