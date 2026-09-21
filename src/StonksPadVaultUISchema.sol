// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Strings} from "@openzeppelin/utils/Strings.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/IVaultSchemasV1.sol";

/// @title StonksPadVaultUISchema
/// @notice External library holding the `vaultUISchema()` payload of `StonksPadVault`.
/// @dev    The schema is ~60 bilingual strings; keeping it inside the vault pushed the runtime
///         bytecode past the 24,576-byte EIP-170 limit. `StonksPadVault.vaultUISchema()` delegates
///         to `build()` (a pure DELEGATECALL into this library), so the on-chain behaviour and the
///         Flap UI contract are unchanged. The library is linked at deploy time.
library StonksPadVaultUISchema {
    /// @notice Builds the static UI schema for `StonksPadVault`. Deployed once as an external
    ///         library so that the schema strings do not count against the vault's EIP-170 size.
    function build() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = "StonksPadVault";
        schema.description = unicode"StonksPad tax vault. After a platform fee, tax revenue is split between fee recipients "
            unicode"(claim BNB with claimFees) and a stock pool that the keeper swaps into tokenized stocks on PancakeSwap; "
            unicode"holders claim their stock share per distribution epoch with claimStocks. If enabled, the capped gas cost of these keeper operations is reimbursed from the stock pool (see opsReserve). / "
            unicode"StonksPad 税收金库。扣除平台费用后，税收在手续费接收者（通过 claimFees 领取 BNB）和股票池之间分配，"
            unicode"keeper 将股票池在 PancakeSwap 上换成代币化股票；持有者通过 claimStocks 按分配期领取股票份额。";

        schema.methods = new VaultMethodSchema[](14);

        // 0 ── stats()
        schema.methods[0].name = "stats";
        schema.methods[0].description = unicode"Aggregate vault counters. / 金库汇总数据。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](7);
        schema.methods[0].outputs[0] = FieldDescriptor("received", "uint256", "Total BNB received", 18);
        schema.methods[0].outputs[1] = FieldDescriptor("net", "uint256", "Total BNB after platform fee", 18);
        schema.methods[0].outputs[2] =
            FieldDescriptor("platformPending", "uint256", "Platform fee not yet withdrawn", 18);
        schema.methods[0].outputs[3] = FieldDescriptor("stockPool", "uint256", "BNB available for stock purchases", 18);
        schema.methods[0].outputs[4] = FieldDescriptor("spentOnStocks", "uint256", "BNB spent on stock purchases", 18);
        schema.methods[0].outputs[5] = FieldDescriptor("buys", "uint256", "Number of stock purchases", 0);
        schema.methods[0].outputs[6] = FieldDescriptor("epochs", "uint256", "Number of distribution epochs", 0);
        schema.methods[0].approvals = new ApproveAction[](0);

        // 1 ── getFeeRoutes()
        schema.methods[1].name = "getFeeRoutes";
        schema.methods[1].description =
        unicode"Fee recipients, their share and claimable BNB. / 手续费接收者、份额及可领取 BNB。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](4);
        schema.methods[1].outputs[0] = FieldDescriptor("recipient", "address", "Fee recipient", 0);
        schema.methods[1].outputs[1] = FieldDescriptor("bps", "uint16", "Share of net revenue in bps", 0);
        schema.methods[1].outputs[2] = FieldDescriptor("claimed", "uint256", "BNB already claimed", 18);
        schema.methods[1].outputs[3] = FieldDescriptor("claimable", "uint256", "BNB claimable now", 18);
        schema.methods[1].approvals = new ApproveAction[](0);
        schema.methods[1].isOutputArray = true;

        // 2 ── getStocks()
        schema.methods[2].name = "getStocks";
        schema.methods[2].description =
            unicode"Configured stock tokens, weights and undistributed balances. / 已配置的股票代币、权重及未分配余额。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](4);
        schema.methods[2].outputs[0] = FieldDescriptor("token", "address", "Stock token", 0);
        schema.methods[2].outputs[1] = FieldDescriptor("bps", "uint16", "Share of net revenue in bps", 0);
        schema.methods[2].outputs[2] =
            FieldDescriptor("undistributed", "uint256", "Bought but not yet assigned to an epoch", 18);
        schema.methods[2].outputs[3] = FieldDescriptor("enabled", "bool", "Enabled in the factory registry", 0);
        schema.methods[2].approvals = new ApproveAction[](0);
        schema.methods[2].isOutputArray = true;

        // 3 ── claimableFees(address)
        schema.methods[3].name = "claimableFees";
        schema.methods[3].description =
        unicode"Claimable fee-route BNB for an address. / 某地址可领取的手续费 BNB。";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("account", "address", "Address to query", 0);
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable BNB", 18);
        schema.methods[3].approvals = new ApproveAction[](0);

        // 4 ── getEpoch(uint256)
        schema.methods[4].name = "getEpoch";
        schema.methods[4].description = unicode"Distribution epoch metadata. / 分配期信息。";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[4].outputs = new FieldDescriptor[](5);
        schema.methods[4].outputs[0] = FieldDescriptor("root", "bytes32", "Merkle root", 0);
        schema.methods[4].outputs[1] = FieldDescriptor("publishedAt", "time", "Publication time", 0);
        schema.methods[4].outputs[2] = FieldDescriptor("claimsOpenAt", "time", "Claims open after this time", 0);
        schema.methods[4].outputs[3] = FieldDescriptor("cancelled", "bool", "True if the epoch was vetoed", 0);
        schema.methods[4].outputs[4] = FieldDescriptor("cid", "string", "IPFS CID of the snapshot", 0);
        schema.methods[4].approvals = new ApproveAction[](0);

        // 5 ── epochRemaining(uint256,address)
        schema.methods[5].name = "epochRemaining";
        schema.methods[5].description =
        unicode"Stock amount still claimable in an epoch. / 某分配期中仍可领取的股票数量。";
        schema.methods[5].inputs = new FieldDescriptor[](2);
        schema.methods[5].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[5].inputs[1] = FieldDescriptor("stock", "address", "Stock token", 0);
        schema.methods[5].outputs = new FieldDescriptor[](1);
        schema.methods[5].outputs[0] = FieldDescriptor("amount", "uint256", "Remaining stock amount", 18);
        schema.methods[5].approvals = new ApproveAction[](0);

        // 6 ── hasClaimed(uint256,address)
        schema.methods[6].name = "hasClaimed";
        schema.methods[6].description =
        unicode"Whether an address already claimed an epoch. / 某地址是否已领取某分配期。";
        schema.methods[6].inputs = new FieldDescriptor[](2);
        schema.methods[6].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[6].inputs[1] = FieldDescriptor("account", "address", "Address to query", 0);
        schema.methods[6].outputs = new FieldDescriptor[](1);
        schema.methods[6].outputs[0] = FieldDescriptor("claimed", "bool", "True if already claimed", 0);
        schema.methods[6].approvals = new ApproveAction[](0);

        // 7 ── minHolding()
        schema.methods[7].name = "minHolding";
        schema.methods[7].description =
            unicode"Minimum token balance required to be included in stock distributions (applied to the keeper snapshot). / 参与股票分配所需的最低代币持仓（应用于 keeper 快照）。";
        schema.methods[7].inputs = new FieldDescriptor[](0);
        schema.methods[7].outputs = new FieldDescriptor[](1);
        schema.methods[7].outputs[0] = FieldDescriptor("minHolding", "uint256", "Minimum holding in tax tokens", 18);
        schema.methods[7].approvals = new ApproveAction[](0);

        // 8 ── epochStocks(uint256)
        schema.methods[8].name = "epochStocks";
        schema.methods[8].description =
        unicode"Stock tokens reserved in an epoch. / 某分配期中预留的股票代币。";
        schema.methods[8].inputs = new FieldDescriptor[](1);
        schema.methods[8].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[8].outputs = new FieldDescriptor[](1);
        schema.methods[8].outputs[0] = FieldDescriptor("stock", "address", "Stock token", 0);
        schema.methods[8].approvals = new ApproveAction[](0);
        schema.methods[8].isOutputArray = true;

        // 9 ── getEpochApproval(uint256)  (v1.1)
        schema.methods[9].name = "getEpochApproval";
        schema.methods[9].description =
            unicode"Snapshot block and independent-verifier approval of an epoch. Approved epochs open claims 30 minutes after approval instead of 24 hours after publication. / 分配期的快照区块与独立验证者批准状态。已批准的分配期在批准 30 分钟后开放领取，而非发布 24 小时后。";
        schema.methods[9].inputs = new FieldDescriptor[](1);
        schema.methods[9].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[9].outputs = new FieldDescriptor[](3);
        schema.methods[9].outputs[0] =
            FieldDescriptor("snapshotBlock", "uint256", "Holder snapshot block (0 = legacy)", 0);
        schema.methods[9].outputs[1] = FieldDescriptor("approvedAt", "time", "Approval time (0 = not approved)", 0);
        schema.methods[9].outputs[2] = FieldDescriptor("fastPath", "bool", "True if approved (verifier or Guardian)", 0);
        schema.methods[9].approvals = new ApproveAction[](0);

        // 10 ── opsReserve()  (v1.1)
        schema.methods[10].name = "opsReserve";
        schema.methods[10].description =
            unicode"Keeper gas reimbursed from the stock pool and the caps that bound it. / 从股票池报销的 keeper gas 及其上限。";
        schema.methods[10].inputs = new FieldDescriptor[](0);
        schema.methods[10].outputs = new FieldDescriptor[](5);
        schema.methods[10].outputs[0] = FieldDescriptor("reimbursedTotal", "uint256", "Total BNB reimbursed", 18);
        schema.methods[10].outputs[1] = FieldDescriptor("reimbursedToday", "uint256", "BNB reimbursed today", 18);
        schema.methods[10].outputs[2] = FieldDescriptor("perCall", "uint256", "Cap per call (BNB)", 18);
        schema.methods[10].outputs[3] = FieldDescriptor("perDay", "uint256", "Cap per day (BNB)", 18);
        schema.methods[10].outputs[4] = FieldDescriptor("maxGasPrice", "uint256", "Gas price cap (wei)", 0);
        schema.methods[10].approvals = new ApproveAction[](0);

        // 11 ── claimFees()
        schema.methods[11].name = "claimFees";
        schema.methods[11].description =
            unicode"Claim your accrued fee-route BNB (fee recipients only). / 领取您累积的手续费 BNB（仅限手续费接收者）。";
        schema.methods[11].inputs = new FieldDescriptor[](0);
        schema.methods[11].outputs = new FieldDescriptor[](0);
        schema.methods[11].approvals = new ApproveAction[](0);
        schema.methods[11].isWriteMethod = true;

        // 12 ── claimStocks(uint256,bytes)
        schema.methods[12].name = "claimStocks";
        schema.methods[12].description = unicode"Claim your stock share for an epoch (opens 24h after publication, or 30 minutes after an independent verifier approval). claimData is generated by the StonksPad site "
            unicode"(abi-encoded stocks, amounts and merkle proof). / 领取某分配期的股票份额。claimData 由 StonksPad 网站生成"
            unicode"（ABI 编码的股票、数量和默克尔证明）。";
        schema.methods[12].inputs = new FieldDescriptor[](2);
        schema.methods[12].inputs[0] = FieldDescriptor("epochId", "uint256", "Epoch id (1-based)", 0);
        schema.methods[12].inputs[1] = FieldDescriptor(
            "claimData", "bytes", "abi.encode(address[] stocks, uint256[] amounts, bytes32[] proof)", 0
        );
        schema.methods[12].outputs = new FieldDescriptor[](0);
        schema.methods[12].approvals = new ApproveAction[](0);
        schema.methods[12].isWriteMethod = true;

        // 13 ── withdrawPlatformFee()
        schema.methods[13].name = "withdrawPlatformFee";
        schema.methods[13].description =
            unicode"Send the accrued platform fee to the platform treasury (anyone can call). / 将累积的平台费用发送至平台金库（任何人均可调用）。";
        schema.methods[13].inputs = new FieldDescriptor[](0);
        schema.methods[13].outputs = new FieldDescriptor[](0);
        schema.methods[13].approvals = new ApproveAction[](0);
        schema.methods[13].isWriteMethod = true;
    }

    /// @notice Bilingual status banner of a vault (moved out of the vault in v1.1 for code size; the
    ///         text is identical to v1.0).
    function describe(uint256 totalReceived_, uint256 buyCount_, uint256 epochCount_)
        external
        pure
        returns (string memory)
    {
        return string.concat(
            "StonksPad Vault: ",
            _fmtBnb(totalReceived_),
            " BNB received, ",
            Strings.toString(buyCount_),
            " stock buys, ",
            Strings.toString(epochCount_),
            " distribution epochs. Fee routes and stock buybacks are claim-based. / ",
            unicode"StonksPad 金库：已收到 ",
            _fmtBnb(totalReceived_),
            unicode" BNB，",
            Strings.toString(buyCount_),
            unicode" 次股票买入，",
            Strings.toString(epochCount_),
            unicode" 轮分配。手续费路由与股票回购均需自行领取。"
        );
    }

    /// @dev Formats wei as "X.YY".
    function _fmtBnb(uint256 wei_) internal pure returns (string memory) {
        uint256 whole = wei_ / 1 ether;
        uint256 cents = (wei_ % 1 ether) / 1e16;
        return string.concat(Strings.toString(whole), ".", cents < 10 ? "0" : "", Strings.toString(cents));
    }
}
