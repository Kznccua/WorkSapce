// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Stake is Ownable, ReentrancyGuard {
    // BSC 链 USDC 地址
    IERC20 public usdc = IERC20(0x8965349fb649A33a30cbFDa057D8eC2C48AbE2A2);

    struct Order {
        address user;
        uint amount;
        uint updateTime;
        uint endTime;
        uint current_totalDevice;
        uint current_totalYeild;
        uint lockDuration;
    }

    Order[] orders;

    uint constant expend_15 = 6.0975e19;    // 121.95 USDC / 2
    uint constant expend_30 = 1.2195e20;    // 121.95 USDC

    //总收益
    uint private totalYeild;
    //总矿机数
    uint private totalDevice;

    uint private yeildOfAdmin;

    //用户的收益
    mapping(bool => mapping(address => uint)) yieldOfUser;
    //用户的本金
    mapping(bool => mapping(address => uint)) balanceOf;
    //orders中对应的订单在用户列表中的位置
    mapping(uint => uint) orderInUserList;
    //用户拥有的订单数量
    mapping(address => uint) orderOfUser;
    //用户所拥有的订单的位置
    mapping(address => mapping(uint => uint)) indexOfUser;
    //佣金
    mapping(address => uint) commission;

    event Depoist(address user, uint amount, uint current_time, uint lockDuration);
    event GetReward(address user, uint amount);
    event Withdraw(address user, uint amount);
    event CountReward();

    constructor(uint _totalYeild, uint _totalDevice) {
        totalYeild = _totalYeild;
        totalDevice = _totalDevice;
    }

    /**
     * @dev 质押
     * @param _amount 质押的 USDC 数量
     * @param _invitation 上级邀请人
     * @param _method 为 false 表示质押 15 天，true 表示质押 30 天
     */
    function depoist(uint _amount, address _invitation, bool _method) public {
        (uint current_totoalDevice, uint current_totalYeild) = _getTotalDeviceAndYield();   // gas saving
        uint expend = _method == true ? expend_30 : expend_15;
        require(current_totoalDevice * current_totalYeild != 0, "Both TotalDevice and TotalYeild can't be zero");
        require(_amount / expend > 0, 'You have least one device');

        usdc.transferFrom(msg.sender, address(this), _amount);

        if(_invitation != address(0)) {
            commission[_invitation] += _amount / 100;
        }

        uint8 lockDuration = _method == true ? 30 : 15;
        Order memory newOrder = Order(msg.sender, _amount, totalYeild, block.timestamp + lockDuration * 1 days, current_totoalDevice, current_totalYeild, lockDuration);

        orders.push(newOrder);
        balanceOf[_method][msg.sender] += _amount;
        uint orderAmounts = orderOfUser[msg.sender];
        orderInUserList[orders.length - 1] = orderAmounts;
        orderOfUser[msg.sender] = orderAmounts + 1;
        indexOfUser[msg.sender][orderAmounts] = orders.length - 1;

        emit Depoist(msg.sender, _amount, block.timestamp, lockDuration);
    }

    // 提取收益
    function getYeild(bool _method) public nonReentrant {
        _countYield(_method);       
        uint amount = yieldOfUser[_method][msg.sender];

        require(amount > 5e19, 'Should exceed 50 USDC');
        uint amountUser = amount * 97 / 100;      // 3% 手续费
        yeildOfAdmin += amount - amountUser;
        usdc.transfer(msg.sender, amountUser);
        emit GetReward(msg.sender, amountUser);
    }

    function withdraw(bool _method) public nonReentrant {
        uint amount;
        uint expend = _method == true ? expend_30 : expend_15;
        uint8 lockTime = _method == true ? 30 : 15;
        uint len = orderOfUser[msg.sender];
        for(uint i = 0; i < len; i++) {
            uint index = indexOfUser[msg.sender][i];
            Order storage order = orders[index];
            if(order.lockDuration != lockTime) {
                continue;
            }
            //如果到达质押时间，但未计算收益
            if(block.timestamp > order.endTime && order.updateTime < order.endTime) {
                uint time = Math.min(order.endTime, block.timestamp);
                uint numerator = order.amount * order.current_totalYeild * time;
                uint denominators = expend * order.current_totalDevice * 2 * lockTime;
                uint yield = numerator / denominators;
                order.updateTime = time;
                yieldOfUser[_method][msg.sender] += yield;
                amount += order.amount;
                //更新数组
                _removeOrder(index);
            } else if (block.timestamp > order.endTime && order.updateTime == order.endTime) {//如果到达质押时间，已经计算收益
                //更新数组
                amount += order.amount;
                _removeOrder(index);
            }
        }
        uint amountUser = amount * 97 / 100;      // 3% 手续费
        yeildOfAdmin += (amount - amountUser);
        usdc.transfer(msg.sender, amountUser);
        emit Withdraw(msg.sender, amountUser);
    }

    //计算收益
    function _countYield(bool _method) private {
        uint expend = _method == true ? expend_30 : expend_15;
        uint8 lockTime = _method == true ? 30 : 15;
        for(uint i = 0; i < orderOfUser[msg.sender]; i++) {
            uint index = indexOfUser[msg.sender][i];
            Order storage order = orders[index];
            if(order.lockDuration != lockTime) {
                continue;
            }
            //判断是否已经计算了收益
            if(order.updateTime == order.endTime) {
                continue;
            }
            uint time = Math.min(order.endTime, block.timestamp);
            uint numerator = order.amount * order.current_totalYeild * time;
            uint denominators = expend * order.current_totalDevice * 2 * lockTime;
            uint yield = numerator / denominators;
            order.updateTime = time;
            yieldOfUser[_method][msg.sender] +=yield;
        }
    }

    // 用户查看计算收益
    function calReward(bool _method) view public returns (uint) {
        uint reward;
        uint expend = _method == true ? expend_30 : expend_15;
        uint8 lockTime = _method == true ? 30 : 15;
        for(uint i = 0; i < orderOfUser[msg.sender]; i++) {
            uint index = indexOfUser[msg.sender][i];
            Order memory order = orders[index];
            //判断是否已经计算了收益
            if(order.lockDuration != lockTime) {
                continue;
            }
            if(order.updateTime == order.endTime) {
                continue;
            }
            uint time = Math.min(order.endTime, block.timestamp);
            uint numerator = order.amount * order.current_totalYeild * time;//time是实际质押的时间
            uint denominators = expend * order.current_totalDevice * 2 * lockTime;//lockTime是原本要质押的时间
            uint yield = numerator / denominators;
            reward += yield;
        }
        return reward;
    }

    function getCommission() public returns(bool) {
        uint amount = checkCommission();
        require(amount > 5e19, 'Should exceed 50 USDC');
        usdc.transfer(msg.sender, amount);
        return true;
    }

    function _removeOrder(uint _indexInOrder) private {       
        //将orders数组进行更新
        Order memory lastOrder = orders[orders.length - 1];
        Order memory order = orders[_indexInOrder];
        orders[_indexInOrder] = lastOrder;        
        //不对indexInUser中下架的Order进行删除，而是将用户持有的订单量减少，采用覆盖的方式进行维护
        uint index = orderInUserList[_indexInOrder];
        address user = order.user;
        indexOfUser[user][index] = indexOfUser[user][orderOfUser[user] - 1];
        orderOfUser[user] = orderOfUser[user] - 1;
        //维护orderInUser
        uint lastOrderInUser = orderInUserList[orders.length - 1];
        indexOfUser[lastOrder.user][lastOrderInUser] = _indexInOrder;
        orderInUserList[_indexInOrder] = lastOrderInUser;
        delete orderInUserList[orders.length - 1];
        orders.pop(); 
    }

    function ckeckYeild(bool _method) public view returns(uint Yeild) {
        return yieldOfUser[_method][msg.sender];
    }

    function checkCommission() view public returns(uint) {
        return commission[msg.sender];
    }

    function setTotalYeild(uint _amount) public onlyOwner() returns(bool) {
        totalYeild = _amount;
        return true;
    }

    function setTotalDevice(uint _amount) public onlyOwner() returns(bool) {
        totalDevice = _amount;
        return true;
    }

    function _getTotalDeviceAndYield() private view returns (uint _totalDevice, uint _totalYield) {
        _totalDevice = totalDevice;
        _totalYield = totalYeild;
    }

    function withdrawByAdmin(address _to) public onlyOwner() {
        uint amount = yeildOfAdmin;
        yeildOfAdmin = 0;
        usdc.transfer(_to, amount);
    }
}