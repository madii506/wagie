// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 *  WAGIE — WagieClock
 *  ------------------------------------------------------------------
 *  "The memecoin that treats you like an employee."
 *
 *  ILLUSTRATIVE, UNAUDITED. This file documents the attendance rules the
 *  WAGIE site describes. Do not deploy it without a review and a test
 *  suite. Numbers, addresses and the payout token are wired at launch.
 *
 *  Rules
 *   - A workday is a Mon–Fri UTC day. `clockIn()` may be called once per
 *     workday by any address holding at least MIN_HOLD of WAGIE.
 *   - Payday is every second Friday. The attendance pool — the creator
 *     share of Pons v2 trade fees collected since the previous payday,
 *     already swapped to the paired stock token ($WDAY) — is split
 *     pro-rata by shifts clocked among holders who are still employed.
 *   - Three consecutive missed workdays = TERMINATED. The holder's shifts
 *     for the period are forfeited to colleagues who clocked in. A
 *     terminated holder may `reapply()` at any time and starts from zero.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract WagieClock {
    IERC20  public immutable WAGIE;     // the memecoin
    IERC20  public immutable PAYROLL;   // the payout token ($WDAY stock token)
    uint256 public immutable MIN_HOLD;  // minimum WAGIE balance to clock in
    address public immutable treasury;  // receives the creator fee share, forwards to this contract

    uint256 public constant DAY = 1 days;
    uint256 public immutable epochStart; // a Monday 00:00 UTC

    struct Employee {
        uint32 lastDay;      // workday index of last clock-in
        uint16 streak;       // consecutive workdays clocked
        uint8  missed;       // consecutive workdays missed (capped at 3)
        bool   employed;
        uint16 periodShifts; // shifts in the current pay period
        uint32 period;       // pay period index the shifts belong to
    }

    mapping(address => Employee) public staff;
    mapping(uint32 => uint256)   public periodShiftTotal;   // period => total shifts credited
    mapping(uint32 => uint256)   public periodPool;         // period => PAYROLL amount paid out
    mapping(uint32 => mapping(address => bool)) public claimed;

    event ClockedIn(address indexed who, uint32 workday, uint16 streak);
    event Terminated(address indexed who, uint32 workday);
    event Reapplied(address indexed who);
    event Payday(uint32 indexed period, uint256 pool, uint256 shifts);
    event Paid(address indexed who, uint32 indexed period, uint256 amount);

    constructor(IERC20 wagie, IERC20 payroll, uint256 minHold, address treasury_, uint256 epochStart_) {
        WAGIE = wagie; PAYROLL = payroll; MIN_HOLD = minHold; treasury = treasury_; epochStart = epochStart_;
    }

    // ---------------------------------------------------------------- time

    /// @dev calendar day index since epochStart (epochStart is a Monday).
    function dayIndex(uint256 ts) public view returns (uint32) {
        return uint32((ts - epochStart) / DAY);
    }
    function isWorkday(uint32 d) public pure returns (bool) { return d % 7 < 5; }          // Mon..Fri
    function workdayIndex(uint32 d) public pure returns (uint32) { return (d / 7) * 5 + (d % 7); }
    function periodOf(uint32 d) public pure returns (uint32) { return d / 14; }             // two-week pay period
    function isPayday(uint32 d) public pure returns (bool) { return d % 14 == 11; }         // second Friday

    // ---------------------------------------------------------------- attendance

    function clockIn() external {
        uint32 d = dayIndex(block.timestamp);
        require(isWorkday(d), "not a workday");
        require(WAGIE.balanceOf(msg.sender) >= MIN_HOLD, "hold WAGIE to clock in");

        Employee storage e = staff[msg.sender];
        _settleMisses(e, d);
        require(e.employed, "terminated: reapply()");
        uint32 w = workdayIndex(d);
        require(e.lastDay != w, "already clocked in today");

        uint32 p = periodOf(d);
        if (e.period != p) { e.period = p; e.periodShifts = 0; }

        // streak continues only if the previous workday was clocked
        e.streak = (e.lastDay + 1 == w) ? e.streak + 1 : 1;
        e.lastDay = w;
        e.missed = 0;
        e.periodShifts += 1;
        periodShiftTotal[p] += 1;

        emit ClockedIn(msg.sender, w, e.streak);
    }

    /// @dev count workdays missed since last clock-in; terminate at 3.
    function _settleMisses(Employee storage e, uint32 d) internal {
        if (!e.employed || e.lastDay == 0) return;
        uint32 w = workdayIndex(d);
        uint32 gap = w > e.lastDay ? w - e.lastDay - 1 : 0; // workdays strictly between
        if (gap == 0) return;
        uint256 m = uint256(e.missed) + gap;
        if (m >= 3) {
            e.employed = false;
            e.missed = 3;
            e.streak = 0;
            // forfeit this period's shifts to colleagues
            uint32 p = periodOf(d);
            if (e.period == p && e.periodShifts > 0) {
                periodShiftTotal[p] -= e.periodShifts;
                e.periodShifts = 0;
            }
            emit Terminated(msg.sender, w);
        } else {
            e.missed = uint8(m);
            e.streak = 0;
        }
    }

    function reapply() external {
        Employee storage e = staff[msg.sender];
        require(!e.employed, "already employed");
        delete staff[msg.sender];
        staff[msg.sender].employed = true;
        emit Reapplied(msg.sender);
    }

    // ---------------------------------------------------------------- payroll

    /// @notice Anyone may run payday once the second Friday has passed.
    ///         Pulls whatever PAYROLL the treasury has forwarded and books it to the period.
    function runPayday(uint32 period) external {
        uint32 d = dayIndex(block.timestamp);
        require(periodOf(d) > period, "period not closed");
        require(periodPool[period] == 0, "already run");
        uint256 pool = PAYROLL.balanceOf(address(this));
        for (uint32 p = 0; p < period; p++) pool -= _unclaimed(p); // leave earlier periods' unclaimed pay intact
        require(pool > 0, "pool is empty");
        periodPool[period] = pool;
        emit Payday(period, pool, periodShiftTotal[period]);
    }

    function claim(uint32 period) external {
        require(periodPool[period] > 0, "payday not run");
        require(!claimed[period][msg.sender], "already paid");
        Employee storage e = staff[msg.sender];
        require(e.employed, "terminated");
        require(e.period == period && e.periodShifts > 0, "no shifts this period");
        uint256 amt = periodPool[period] * e.periodShifts / periodShiftTotal[period];
        claimed[period][msg.sender] = true;
        require(PAYROLL.transfer(msg.sender, amt), "transfer failed");
        emit Paid(msg.sender, period, amt);
    }

    function _unclaimed(uint32) internal pure returns (uint256) { return 0; } // bookkeeping stub for the illustration

    // ---------------------------------------------------------------- views

    function statusOf(address who) external view returns (bool employed, uint16 streak, uint8 missed, uint16 shifts) {
        Employee memory e = staff[who];
        return (e.employed || e.lastDay == 0, e.streak, e.missed, e.periodShifts);
    }
}
