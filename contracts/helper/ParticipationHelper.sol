/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/
pragma solidity 0.4.24;
pragma experimental "v0.5.0";
pragma experimental "ABIEncoderV2";

import "../impl/Data.sol";
import "../lib/MathUint.sol";
import "./OrderHelper.sol";
import "./TaxHelper.sol";


/// @title ParticipationHelper
/// @author Daniel Wang - <daniel@loopring.org>.
library ParticipationHelper {
    using MathUint for uint;
    using OrderHelper for Data.Order;
    using TaxHelper for Data.Tax;

    function setMaxFillAmounts(
        Data.Participation p,
        Data.Context ctx
        )
        internal
    {
        uint spendableS = p.order.getSpendableS(ctx);
        uint remainingS = p.order.amountS.sub(p.order.filledAmountS);
        p.fillAmountS = (spendableS < remainingS) ? spendableS : remainingS;
        if (p.order.P2P) {
            // If this is a P2P ring we may have to pay a (pre-trading) percentage tokenS to
            // the wallet. We have to make sure the order owner can pay that percentage,
            // otherwise we'll have to sell less tokenS.
            uint feeS = p.fillAmountS.calculatePreTradingPercentage(
                p.order.tokenSFeePercentage,
                ctx.feePercentageBase
            );

            uint totalAmountS = p.fillAmountS + feeS;
            if (totalAmountS > spendableS) {

                uint maxFeeAmountS = spendableS
                    .mul(p.order.tokenSFeePercentage) / ctx.feePercentageBase;

                p.fillAmountS = spendableS - maxFeeAmountS;
            }
        }
        p.fillAmountB = p.fillAmountS.mul(p.order.amountB) / p.order.amountS;
    }

    function calculateFeesAndTaxes(
        Data.Participation p,
        Data.Participation prevP,
        Data.Context ctx
        )
        internal
    {
        if (p.order.P2P) {
            // Calculate P2P fees
            p.feeAmount = 0;
            if (p.order.wallet != 0x0) {
                p.feeAmountS = p.fillAmountS.calculatePreTradingPercentage(
                    p.order.tokenSFeePercentage,
                    ctx.feePercentageBase
                );
                p.feeAmountB = p.fillAmountB.mul(p.order.tokenBFeePercentage) / ctx.feePercentageBase;
            } else {
                p.feeAmountS = 0;
                p.feeAmountB = 0;
            }

            // The taker gets the margin
            p.splitS = 0;
            p.fillAmountS = prevP.fillAmountB;
        } else {
            // Calculate matching fees
            p.feeAmount = p.order.feeAmount.mul(p.fillAmountS) / p.order.amountS;
            p.feeAmountS = 0;
            p.feeAmountB = 0;

            // We have to pay with tokenB if the owner can't pay the complete feeAmount in feeToken
            // This and subsequent orders could use tokenS to pay fees,
            // so we have to make sure the funds needed for this order cannot be used
            p.order.reserveAmountS(p.fillAmountS);
            uint spendableFee = p.order.getSpendableFee(ctx);
            if (p.feeAmount > spendableFee) {
                p.feeAmountB = p.fillAmountB.mul(p.order.feePercentage) / ctx.feePercentageBase;
                p.feeAmount = 0;
            } else {
                p.order.reserveAmountFee(p.feeAmount);
            }

            // Miner can waive fees for this order. If waiveFeePercentage > 0 this is a simple reduction in fees.
            if (p.order.waiveFeePercentage > 0) {
                p.feeAmount = p.feeAmount.mul(
                    ctx.feePercentageBase - uint(p.order.waiveFeePercentage)) / ctx.feePercentageBase;
                p.feeAmountB = p.feeAmountB.mul(
                    ctx.feePercentageBase - uint(p.order.waiveFeePercentage)) / ctx.feePercentageBase;
                // fillAmountFeeS is always 0
            } else if (p.order.waiveFeePercentage < 0) {
                // No fees need to be paid by this order
                p.feeAmount = 0;
                p.feeAmountB = 0;
            }

            // The miner/wallet gets the margin
            p.splitS = p.fillAmountS - prevP.fillAmountB;
            p.fillAmountS = prevP.fillAmountB;
        }
    }

    function adjustOrderState(
        Data.Participation p
        )
        internal
        pure
    {
        uint filledAmountS = p.fillAmountS + p.splitS;
        uint totalAmountS = filledAmountS;
        uint totalAmountFee = p.feeAmount;
        p.order.filledAmountS += filledAmountS;
        // Update spendables
        p.order.tokenSpendableS.amount = p.order.tokenSpendableS.amount.sub(totalAmountS);
        p.order.tokenSpendableFee.amount = p.order.tokenSpendableFee.amount.sub(totalAmountFee);
        if (p.order.brokerInterceptor != 0x0) {
            p.order.brokerSpendableS.amount = p.order.brokerSpendableS.amount.sub(totalAmountFee);
            p.order.brokerSpendableFee.amount = p.order.brokerSpendableFee.amount.sub(totalAmountS);
        }
    }

}
